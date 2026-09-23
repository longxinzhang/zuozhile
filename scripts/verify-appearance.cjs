#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app';
const ts = require(path.join(sdk, 'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
function load(file, mocks, globals = {}) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(read('entry/src/main/ets/' + file + '.ets'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText, { module, exports: module.exports, ...globals, require: name => {
    if (mocks[name]) return mocks[name];
    assert.ok(name.startsWith('.'), `Unexpected dependency: ${name}`);
    return load(path.posix.join(path.posix.dirname(file), name), mocks, globals);
  } });
  return module.exports;
}
const normalize = load('theme/AppearanceOptions', {}).normalizeImmersiveLevel;
for (const [input, expected] of [[NaN, 3], [Infinity, 3], [-1, 1], [0, 1], [6, 5], [2.6, 3], [5, 5]]) {
  assert.equal(normalize(input), expected);
}

async function main() {
  let value = 3, failGet = false, failPut = false, failFlush = false, active = 0, maxActive = 0;
  const store = load('services/AppearanceStore', {
    '@kit.ArkData': { preferences: { getPreferences: async (context, options) => {
      assert.equal(options.name, 'zuozhile_appearance');
      if (failGet) throw Error('read failure');
      return {
        get: async key => { assert.equal(key, 'immersive_level'); return value; },
        put: async (key, next) => {
          assert.equal(key, 'immersive_level');
          if (failPut) throw Error('write failure');
          active++; maxActive = Math.max(maxActive, active);
          await new Promise(resolve => setTimeout(resolve, next === 1 ? 20 : 1));
          value = next; active--;
        },
        flush: async () => { if (failFlush) throw Error('flush failure'); }
      };
    } } }
  }).AppearanceStore;
  for (const raw of [3, 'invalid', null, NaN, -20, 99]) {
    value = raw;
    const result = await store.load({});
    assert.equal(result.level, typeof raw === 'number' ? normalize(raw) : 3);
    assert.equal(result.isHealthy, true);
  }
  failGet = true;
  assert.equal((await store.load({})).isHealthy, false);
  assert.equal((await store.load({})).level, 3);
  failGet = false;
  assert.deepEqual(await Promise.all([store.save({}, 1), store.save({}, 2), store.save({}, 5)]), [true, true, true]);
  assert.equal(value, 5); assert.equal(maxActive, 1);
  failPut = true; assert.equal(await store.save({}, 2), false);
  failPut = false; failFlush = true; assert.equal(await store.save({}, 4), false);
  failFlush = false; assert.equal(await store.save({}, 3), true);
  assert.equal((await store.load({})).level, 3);
  console.log('PASS: appearance defaults, bounds, separate storage, serialized rapid changes, error reporting and retry');

  const ast = ts.createSourceFile('Index.ts', read('entry/src/main/ets/pages/Index.ets').replace('struct Index {', 'class Index {'),
    ts.ScriptTarget.Latest, true);
  const page = ast.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'Index');
  const setter = page.members.find(node => node.name?.getText(ast) === 'setImmersiveLevel').getText(ast);
  const pending = [];
  const controller = vm.runInNewContext(ts.transpileModule(`class Test { ${setter} } new Test();`, {
    compilerOptions: { target: ts.ScriptTarget.ES2020 }
  }).outputText, { normalizeImmersiveLevel: normalize,
    AppearanceStore: { save: (context, level) => new Promise(resolve => pending.push({ level, resolve })) } });
  Object.assign(controller, { appearanceReady: true, immersiveSupported: true, immersiveLevel: 3,
    appearanceError: '', appearanceSaveId: 0, pageRunId: 1, abilityContext: () => ({}),
    controlsLocked: () => false, isCurrentPageRun: id => id === controller.pageRunId });
  const first = controller.setImmersiveLevel(1), last = controller.setImmersiveLevel(5);
  pending[1].resolve(true); await last;
  pending[0].resolve(false); await first;
  assert.equal(controller.immersiveLevel, 5); assert.equal(controller.appearanceError, '');
  const failure = controller.setImmersiveLevel(2); pending[2].resolve(false); await failure;
  assert.match(controller.appearanceError, /未保存/);
  const retry = controller.setImmersiveLevel(2); pending[3].resolve(true); await retry;
  assert.equal(controller.appearanceError, '');
  controller.controlsLocked = () => true;
  await controller.setImmersiveLevel(3); assert.equal(controller.immersiveLevel, 2);
  controller.controlsLocked = () => false;
  const stale = controller.setImmersiveLevel(4); controller.pageRunId++;
  pending[4].resolve(false); await stale; assert.equal(controller.appearanceError, '');
  console.log('PASS: live selection, stale completion isolation, failed-save retry and calibration/busy lock');

  const calls = [];
  const ability = load('entryability/EntryAbility', {
    '@kit.AbilityKit': { UIAbility: class {}, ConfigurationConstant: { ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1 } } },
    '@kit.PerformanceAnalysisKit': { hilog: { warn() {}, info() {} } },
    '../services/PostureFloatService': {}, '../services/GuardWindowService': {},
    '../services/ARFaceCapability': {}, '../services/AppearanceStore': {}
  }, { AppStorage: { setOrCreate() {} } });
  const instance = new ability.default();
  instance.context = { config: { colorMode: 1 } };
  instance.mainWindow = { setWindowSystemBarProperties: async options => calls.push(options) };
  for (const dark of [false, true, false]) {
    instance.onConfigurationUpdate({ colorMode: dark ? 0 : 1 });
    const colors = Object.fromEntries(JSON.parse(read(`entry/src/main/resources/${dark ? 'dark' : 'base'}/element/color.json`))
      .color.map(item => [item.name, item.value]));
    assert.equal(calls.at(-1).navigationBarColor, colors.app_bg);
    assert.equal(calls.at(-1).statusBarColor, colors.app_bg);
    assert.equal(calls.at(-1).navigationBarContentColor, colors.ink);
  }
  const lightNames = JSON.parse(read('entry/src/main/resources/base/element/color.json')).color.map(c => c.name).sort();
  const darkNames = JSON.parse(read('entry/src/main/resources/dark/element/color.json')).color.map(c => c.name).sort();
  assert.deepEqual(lightNames, darkNames);
  assert.equal(new Set(lightNames).size, lightNames.length);
  console.log('PASS: runtime system bar theme updates and complete matching light/dark resource keys');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
