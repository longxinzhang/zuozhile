#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const today = new Date();
const day = [today.getFullYear(), String(today.getMonth() + 1).padStart(2, '0'),
  String(today.getDate()).padStart(2, '0')].join('-');
const output = path.join(root, 'artifacts', 'preview-' + day);
const hdc = process.env.HDC || '/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/toolchains/hdc';
const manual = process.argv.includes('--manual');
const label = manual ? 'manual' : 'quick';
fs.mkdirSync(output, { recursive: true });
function run(...args) { return execFileSync(hdc, args, { encoding: 'utf8', timeout: 15000 }); }
function layout(name) {
  const remote = '/data/local/tmp/zuozhile-cancel.json';
  const local = path.join(output, name + '.json');
  assert.match(run('shell', `uitest dumpLayout -p ${remote}`), /DumpLayout saved/);
  run('file', 'recv', remote, local);
  const nodes = [];
  function walk(value, inheritedBundle = '') {
    if (!value || typeof value !== 'object') return;
    const bundle = value.attributes?.bundleName || inheritedBundle;
    if (value.attributes?.visible === 'true' && bundle === 'com.longxin.zuozhile') {
      nodes.push(value.attributes);
    }
    for (const child of Object.values(value)) {
      if (Array.isArray(child)) child.forEach(item => walk(item, bundle));
      else if (child && typeof child === 'object') walk(child, bundle);
    }
  }
  walk(JSON.parse(fs.readFileSync(local, 'utf8')));
  return nodes;
}
function tap(nodes, text) {
  const node = nodes.find(n => n.text === text);
  assert.ok(node, `Visible control missing: ${text}`);
  const bounds = node.bounds.match(/\d+/g).map(Number);
  const x = Math.round((bounds[0] + bounds[2]) / 2);
  const y = Math.round((bounds[1] + bounds[3]) / 2);
  assert.match(run('shell', `uitest uiInput click ${x} ${y}`), /No Error/);
}

let nodes = layout(label + '-before');
assert.ok(nodes.length > 0, 'Open the app before running this test');
tap(nodes, manual ? '设置' : '守护');
nodes = layout(label + '-ready');
tap(nodes, manual ? '校准坐姿' : '开始守护');
const start = Date.now();
nodes = layout(label + '-countdown');
tap(nodes, '取消校准');
const elapsedMs = Date.now() - start;
for (let retry = 0; retry < 4; retry++) {
  nodes = layout(label + '-cancelled');
  if (nodes.some(n => n.text?.includes('已取消校准，原基线未更改'))) break;
}
assert.ok(nodes.some(n => n.text?.includes('已取消校准，原基线未更改')));
assert.ok(!nodes.some(n => n.text === '结束守护'));
assert.ok(!nodes.some(n => n.text === '取消校准'));
console.log(`PASS: ${label} calibration cancelled in ${elapsedMs}ms after click; no guard session started`);
