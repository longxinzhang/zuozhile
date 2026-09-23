#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const hdc = process.env.HDC || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const target = process.env.HDC_TARGET ? ['-t', process.env.HDC_TARGET] : [];
const output = path.join(root, 'artifacts', 'preview-' + new Date().toLocaleDateString('en-CA'));
fs.mkdirSync(output, { recursive: true });
const run = (...args) => execFileSync(hdc, [...target, ...args], { encoding: 'utf8', timeout: 20000 });
const bounds = node => node.bounds.match(/-?\d+/g).map(Number);
const wait = () => new Promise(resolve => setTimeout(resolve, 500));

function layout(name) {
  const remote = '/data/local/tmp/zuozhile-ui-check.json';
  const local = path.join(output, name + '.json');
  assert.match(run('shell', `uitest dumpLayout -p ${remote}`), /DumpLayout saved/);
  run('file', 'recv', remote, local);
  const nodes = [];
  function walk(value, bundle = '', parents = []) {
    if (!value || typeof value !== 'object') return;
    const attributes = value.attributes;
    const currentBundle = attributes?.bundleName || bundle;
    const ancestry = attributes ? [...parents, attributes.type] : parents;
    if (attributes?.visible === 'true' && currentBundle === 'com.longxin.zuozhile') {
      nodes.push({ ...attributes, parents });
    }
    for (const [key, child] of Object.entries(value)) {
      if (key === 'attributes') continue;
      if (Array.isArray(child)) child.forEach(item => walk(item, currentBundle, ancestry));
      else if (child && typeof child === 'object') walk(child, currentBundle, ancestry);
    }
  }
  walk(JSON.parse(fs.readFileSync(local, 'utf8')));
  assert.ok(nodes.some(node => node.type === 'Navigation'), 'Unlock and open the app before testing');
  return nodes;
}

function tap(node) {
  assert.ok(node, 'Control must be visible before tapping');
  const [left, top, right, bottom] = bounds(node);
  assert.match(run('shell', `uitest uiInput click ${Math.round((left + right) / 2)} ${Math.round((top + bottom) / 2)}`), /No Error/);
}

function snapshot(name) {
  const nodes = layout(name);
  const remote = `/data/local/tmp/${name}.jpeg`;
  assert.match(run('shell', `snapshot_display -f ${remote}`), /success: snapshot/);
  run('file', 'recv', remote, path.join(output, name + '.jpeg'));
  return nodes;
}

async function tab(nodes, label) {
  tap(nodes.find(node => node.text === label && node.parents.includes('TabBar') && node.clickable === 'true'));
  await wait();
  return layout('025-current');
}

async function main() {
  let nodes = await tab(layout('025-before'), '守护');
  assert.ok(nodes.some(node => node.text === '开始守护'), 'Run this read-only check with guarding stopped');
  nodes = snapshot('025-home');
  const title = nodes.find(node => node.type === 'TitleBar');
  const scroll = nodes.find(node => node.type === 'Scroll');
  assert.ok(Math.abs(bounds(title)[3] - bounds(scroll)[1]) <= 2, 'Short pages must not be vertically centered');
  const barTop = bounds(nodes.find(node => node.type === 'TabBar'))[1];
  for (const text of ['开始守护', '姿态建议', '坐稳，肩膀放松']) {
    const node = nodes.find(item => item.text === text);
    assert.ok(node && bounds(node)[3] < barTop, `${text} must fit above the tab bar`);
  }
  tap(nodes.find(node => node.type === 'Button' && node.parents.includes('TitleBar')));
  await wait();
  nodes = snapshot('025-settings');
  assert.ok(nodes.some(node => node.text === '坐姿校准'));
  assert.ok(nodes.some(node => node.text === '识别设置'));
  assert.ok(!nodes.some(node => node.text?.includes('坐姿浮窗')));
  const [left, top, right, bottom] = bounds(nodes.find(node => node.type === 'Scroll'));
  const x = Math.round((left + right) / 2);
  assert.match(run('shell', `uitest uiInput swipe ${x} ${Math.round(top + (bottom - top) * 0.78)} ${x} ${Math.round(top + (bottom - top) * 0.2)} 600`), /No Error/);
  await wait();
  nodes = snapshot('025-settings-bottom');
  const clear = nodes.find(node => node.text === '清空本机数据');
  assert.ok(clear && bounds(clear)[3] < bounds(nodes.find(node => node.type === 'TabBar'))[1]);
  assert.ok(!nodes.some(node => node.text?.includes('坐姿浮窗')));
  nodes = await tab(nodes, '统计');
  nodes = snapshot('025-stats');
  assert.ok(nodes.some(node => node.text === '今日概览'));
  nodes = await tab(nodes, '指南');
  nodes = snapshot('025-guide');
  assert.ok(nodes.some(node => node.text === '调整前'));
  assert.ok(nodes.some(node => node.text === '调整后'));
  nodes = await tab(nodes, '守护');
  assert.ok(nodes.some(node => node.text === '开始守护'));
  console.log('PASS: four native tabs, header settings shortcut, first-screen actions, top alignment and settings bottom clearance');
  console.log('Screenshots: ' + output);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
