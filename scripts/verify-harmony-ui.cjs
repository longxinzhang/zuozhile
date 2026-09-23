#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const baseline = 'e0806ab';
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app';
const ts = require(path.join(sdk, 'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const prior = file => execFileSync('git', ['show', `${baseline}:${file}`], { cwd: root, encoding: 'utf8' });
const protectedPaths = execFileSync('git', ['ls-files', 'entry/src/main/ets/models', 'entry/src/main/cpp'],
  { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(file => !file.endsWith('/FloatingStatus.ets'));
for (const service of ['ARPostureSource', 'ARFaceCapability', 'CoreVisionPostureDetector', 'CoreVisionPostureSource',
  'MockFrameSampler', 'MockPostureSource', 'PostureSessionStore', 'ReminderFeedbackService', 'CameraProbeService', 'GuardWindowService']) {
  protectedPaths.push(`entry/src/main/ets/services/${service}.ets`);
}
for (const file of protectedPaths) assert.equal(read(file), prior(file), `Core change: ${file}`);

function methods(text) {
  const ast = ts.createSourceFile('Index.ts', text.replace('struct Index {', 'class Index {'), ts.ScriptTarget.Latest, true);
  const page = ast.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'Index');
  return new Map(page.members.filter(ts.isMethodDeclaration).map(node => [node.name.getText(ast), node.getText(ast)]));
}
const indexPath = 'entry/src/main/ets/pages/Index.ets';
const oldMethods = methods(prior(indexPath)), newMethods = methods(read(indexPath));
const coreMethods = ['startGuard', 'stopGuard', 'runCalibration', 'captureFrame', 'appendRecord', 'applyResult',
  'applySitMetric', 'applyChinMetric', 'applyMouthMetric', 'shouldAdoptMetric', 'buildSessionReport',
  'setSensitivity', 'setIntervalMs', 'copySettings', 'onForegroundChanged'];
for (const name of coreMethods) assert.equal(newMethods.get(name), oldMethods.get(name), `Core method change: ${name}`);
console.log(`PASS: ${protectedPaths.length} algorithm/native/source files and ${coreMethods.length} core page methods unchanged from ${baseline}`);
const allowedNonVisualChanges = new Set(['build', 'syncFloatingState', 'toggleFloatingWindow', 'todayInsightText']);
let unchangedMethods = 0;
for (const [name, body] of oldMethods) {
  if (/^@Builder\b/.test(body) || allowedNonVisualChanges.has(name)) continue;
  assert.equal(newMethods.get(name), body, `Unexpected non-visual method change: ${name}`);
  unchangedMethods++;
}
assert.match(newMethods.get('todayInsightText'), /const issues = this\.alertBreakdown\(\)/);
console.log(`PASS: ${unchangedMethods} non-builder methods unchanged; only retained float state and insight display copy are excepted`);

function load(file, dependencies) {
  const module = { exports: {} };
  const code = ts.transpileModule(read('entry/src/main/ets/' + file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, BarStyle: { STANDARD: 0 }, require: name => {
    assert.ok(dependencies[name], name); return dependencies[name];
  } });
  return module.exports;
}
for (const modern of [false, true]) {
  let materials = 0;
  const calls = [];
  const theme = load('theme/ImmersiveSurface', {
    '@kit.BasicServicesKit': { deviceInfo: { apiAvailable: version => {
      assert.equal(version, '26.0.0'); return modern;
    } } },
    '@kit.ArkUI': { uiMaterial: { ImmersiveStyle: { REGULAR: 1 }, ImmersiveMaterial: class {
      constructor(options) { assert.ok(modern, 'Legacy API must not construct API 26 material'); this.options = options; materials++; }
    } } }
  });
  const attributes = {
    systemMaterial(value) { calls.push(['material', value.options]); return this; },
    barOverlap(value) { calls.push(['overlap', value]); return this; },
    barFloatingStyle(value) { calls.push(['floating', value]); return this; },
    barBackgroundColor(value) { calls.push(['background', value]); return this; }
  };
  new theme.ImmersiveSurface('#D9138654').applyNormalAttribute(attributes);
  new theme.HarmonyTabBar().applyNormalAttribute(attributes);
  const title = theme.navigationTitleOptions();
  assert.equal(title.barStyle, 0);
  assert.equal(Boolean(title.systemMaterial), modern);
  if (!modern) assert.equal(title.backgroundColor, '#F4F5F7');
  assert.equal(materials, modern ? 3 : 0);
  assert.equal(theme.navigationBottomInset(), modern ? 96 : 24);
  assert.equal(calls.some(call => call[0] === 'floating'), modern);
  if (modern) assert.equal(calls[0][1].materialColor, '#D9138654');
}
console.log('PASS: API 26 title material and floating tabs isolated from old systems; navigation content reserves bottom space');

assert.match(newMethods.get('build'), /Navigation\(\)/);
assert.match(newMethods.get('build'), /navigationTitleOptions\(\)/);
assert.match(newMethods.get('PageBody'), /\.height\('100%'\)/);
assert.match(newMethods.get('Header'), /this\.switchTab\(3\)/);
assert.doesNotMatch(newMethods.get('Header'), /toggleFloatingWindow|floatVisible/);
assert.doesNotMatch(newMethods.get('SettingsPage'), /this\.FloatingPanel\(\)/);
assert.doesNotMatch(read('entry/src/main/module.json5'), /ohos\.permission\.FLOAT_VIEW/);
console.log('PASS: native Navigation owns the title; floating-window entries and restricted permission remain disabled');

const systemResources = fs.readFileSync(path.join(sdk,
  'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/sysResource.js'), 'utf8');
for (const file of [indexPath, 'entry/src/main/ets/components/PostureMetricTile.ets']) {
  for (const [, symbol] of read(file).matchAll(/\$r\('sys\.symbol\.([^']+)'\)/g)) {
    assert.match(systemResources, new RegExp('\\b' + symbol + ': \\d+'), `Unknown system symbol: ${symbol}`);
  }
}
console.log('PASS: system symbol names exist in the installed SDK');

const floating = load('models/FloatingStatus', {});
const now = 100000;
const reading = { score: 92, timestamp: now, summary: '坐姿在线', guarding: true, foreground: true, simulated: false };
assert.equal(floating.floatingScore(reading, now), '92');
assert.equal(floating.hasFloatingReading(reading, now), true);
for (const patch of [{ timestamp: now + 1 }, { timestamp: 0 }, { timestamp: now - 15001 }, { score: NaN },
  { score: -1 }, { score: 101 }, { score: Infinity }, { foreground: false }, { guarding: false }]) {
  assert.equal(floating.floatingScore({ ...reading, ...patch }, now), '--');
  assert.equal(floating.hasFloatingReading({ ...reading, ...patch }, now), false);
}
assert.ok(floating.floatingStatus({ ...reading, simulated: true }, now).includes('模拟'));
assert.match(read('entry/src/main/ets/pages/PostureFloat.ets'), /@Prop label: string/);
console.log('PASS: no stale/invalid/background floating score or metric details; simulated data explicit and reactive props preserved');
