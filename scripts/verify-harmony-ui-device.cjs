#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const hdc = process.env.HDC || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const target = process.env.HDC_TARGET ? ['-t', process.env.HDC_TARGET] : [];
const prefix = process.env.UI_SNAPSHOT_PREFIX || '026-light';
const output = path.join(root, 'artifacts', 'preview-' + new Date().toLocaleDateString('en-CA'));
fs.mkdirSync(output, { recursive: true });
const run = (...args) => execFileSync(hdc, [...target, ...args], { encoding: 'utf8', timeout: 20000 });
const bounds = node => node.bounds.match(/-?\d+/g).map(Number);
const wait = () => new Promise(resolve => setTimeout(resolve, 500));

function layout(name) {
  const remote = '/data/local/tmp/zuozhile-ui-check.json';
  const local = path.join(output, prefix + '-' + name + '.json');
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
  const remote = `/data/local/tmp/${prefix}-${name}.jpeg`;
  assert.match(run('shell', `snapshot_display -f ${remote}`), /success: snapshot/);
  run('file', 'recv', remote, path.join(output, prefix + '-' + name + '.jpeg'));
  return nodes;
}

async function tab(nodes, label) {
  tap(nodes.find(node => node.text === label && node.parents.includes('TabBar') && node.clickable === 'true'));
  await wait();
  return layout('current');
}

async function selectLevel(nodes, level) {
  const slider = nodes.find(node => node.id === 'immersive-level-slider' && node.type === 'Slider');
  assert.ok(slider && slider.enabled === 'true', 'Material slider must be supported and ready');
  const [left, top, right, bottom] = bounds(slider);
  const x = Math.round(left + (right - left) * (0.04 + 0.92 * (level - 1) / 4));
  assert.match(run('shell', `uitest uiInput click ${x} ${Math.round((top + bottom) / 2)}`), /No Error/);
  await wait();
  nodes = layout('level-' + level);
  assert.ok(nodes.some(node => node.text === `${level} / 5`), 'Selected level must update immediately');
  assert.ok(!nodes.some(node => node.text?.includes('未保存')));
  return nodes;
}

function settingButton(nodes, label) {
  const text = nodes.find(node => node.text === label);
  assert.ok(text, label + ' must be visible');
  const b = bounds(text);
  return nodes.find(node => node.type === 'Button' && bounds(node)[0] <= b[0] &&
    bounds(node)[1] <= b[1] && bounds(node)[2] >= b[2] && bounds(node)[3] >= b[3]);
}

async function checkSettingChoices(nodes) {
  for (const labels of [['标准', '灵敏'], ['2 秒', '3 秒', '5 秒']]) {
    const initial = labels.find(label => settingButton(nodes, label)?.backgroundColor !== '#00000000');
    assert.ok(initial, 'Must identify the original selection before changing settings');
    try {
      for (const label of labels) {
        tap(settingButton(nodes, label));
        await wait();
        nodes = layout('choices');
        assert.notEqual(settingButton(nodes, label).backgroundColor, '#00000000', label + ' must be selected');
        for (const other of labels.filter(value => value !== label)) {
          assert.equal(settingButton(nodes, other).backgroundColor, '#00000000', other + ' must be unselected');
        }
      }
    } finally {
      tap(settingButton(layout('choices-restore'), initial));
      await wait();
      nodes = layout('choices-restored');
    }
  }
  console.log('PASS: sensitivity and interval controls remain selectable; original choices restored');
  return nodes;
}

async function main() {
  let nodes = await tab(layout('before'), '守护');
  assert.ok(nodes.some(node => node.text === '开始守护'), 'Run this read-only check with guarding stopped');
  nodes = snapshot('home');
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
  nodes = snapshot('settings');
  assert.ok(nodes.some(node => node.text === '坐姿校准'));
  assert.ok(nodes.some(node => node.text === '识别设置'));
  assert.ok(!nodes.some(node => node.text?.includes('坐姿浮窗')));
  if (process.argv.includes('--levels')) {
    const initial = Number(nodes.find(node => /^\d \/ 5$/.test(node.text))?.text[0]);
    assert.ok(initial >= 1 && initial <= 5);
    for (const level of [1, 2, 3, 4, 5]) {
      nodes = await selectLevel(nodes, level);
      if ([1, 3, 5].includes(level)) nodes = snapshot('material-' + level);
    }
    run('shell', 'aa force-stop com.longxin.zuozhile');
    assert.match(run('shell', 'aa start -a EntryAbility -b com.longxin.zuozhile'), /start ability successfully/);
    await wait();
    nodes = await tab(layout('restarted'), '设置');
    assert.ok(nodes.some(node => node.text === '5 / 5'), 'Material preference must survive app restart');
    nodes = await selectLevel(nodes, initial);
    nodes = snapshot('settings');
    console.log('PASS: five live levels and persistence after process restart; initial level restored');
  }
  if (process.argv.includes('--settings')) nodes = await checkSettingChoices(nodes);
  const [left, top, right, bottom] = bounds(nodes.find(node => node.type === 'Scroll'));
  const x = Math.round((left + right) / 2);
  for (let attempt = 0; attempt < 4; attempt++) {
    const clear = nodes.find(node => node.text === '清空本机数据');
    if (clear && bounds(clear)[3] < bounds(nodes.find(node => node.type === 'TabBar'))[1]) break;
    assert.match(run('shell', `uitest uiInput swipe ${x} ${Math.round(top + (bottom - top) * 0.78)} ${x} ${Math.round(top + (bottom - top) * 0.2)} 600`), /No Error/);
    await wait();
    nodes = layout('settings-scrolled');
  }
  nodes = snapshot('settings-bottom');
  const clear = nodes.find(node => node.text === '清空本机数据');
  assert.ok(clear && bounds(clear)[3] < bounds(nodes.find(node => node.type === 'TabBar'))[1]);
  assert.ok(!nodes.some(node => node.text?.includes('坐姿浮窗')));
  nodes = await tab(nodes, '统计');
  nodes = snapshot('stats');
  assert.ok(nodes.some(node => node.text === '今日概览'));
  nodes = await tab(nodes, '指南');
  nodes = snapshot('guide');
  assert.ok(nodes.some(node => node.text === '调整前'));
  assert.ok(nodes.some(node => node.text === '调整后'));
  nodes = await tab(nodes, '守护');
  assert.ok(nodes.some(node => node.text === '开始守护'));
  console.log('PASS: four native tabs, header settings shortcut, first-screen actions, top alignment and settings bottom clearance');
  console.log('Screenshots: ' + output);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
