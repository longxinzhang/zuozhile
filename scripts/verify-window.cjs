#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const ts = require('/Applications/DevEco-Studio.app/Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript');

function load(file, dependencies, store, timers = new Map()) {
  const code = ts.transpileModule(fs.readFileSync(path.join(root, 'entry/src/main/ets/services', file), 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  const module = { exports: {} };
  vm.runInNewContext(code, { module, exports: module.exports,
    AppStorage: { get: key => store.get(key), setOrCreate: (key, value) => store.set(key, value) },
    setTimeout: callback => { const id = timers.size + 1; timers.set(id, callback); return id; },
    clearTimeout: id => timers.delete(id),
    require: name => { assert.ok(dependencies[name], name); return dependencies[name]; }
  });
  return module.exports;
}

function fixture({ native = false, declared = true, granted = true, fail = false,
  holdPermission = false, holdContent = false, stopFails = false, deferStop = false } = {}) {
  const store = new Map();
  const calls = [];
  const timers = new Map();
  let stateChange;
  let releasePermission, releaseContent;
  const permissionGate = new Promise(resolve => { releasePermission = resolve; });
  const contentGate = new Promise(resolve => { releaseContent = resolve; });
  const controller = {
    onStateChange: callback => { stateChange = callback; }, offStateChange: () => {},
    onRectChange: () => {}, offRectChange: () => {},
    getWindowProperties: () => ({ avoidArea: { topRect: { height: 72 }, bottomRect: { height: 0 } } }),
    setWindowSize: async size => { assert.ok(size.width >= 200 && size.width <= 1200); },
    setUIContext: async page => {
      assert.equal(page, 'pages/PostureFloat'); if (holdContent) await contentGate;
    },
    start: async () => { calls.push('native-start'); if (fail) throw new Error('not supported'); },
    stop: async () => {
      calls.push('native-stop'); if (stopFails) throw new Error('system busy');
      if (!deferStop) stateChange({ state: 'stopped' });
    },
    restoreMainWindow: async () => calls.push('restore-native')
  };
  const child = {
    resize: async () => {}, moveWindowTo: async () => {}, setUIContent: async () => {},
    setWindowBackgroundColor: async () => { throw new Error('phone unsupported'); },
    showWindow: async () => calls.push('child-show'), destroyWindow: async () => calls.push('child-destroy'),
    startMoving: async () => calls.push('child-move')
  };
  const service = load('PostureFloatService.ets', {
    '@kit.AbilityKit': { bundleManager: {
      BundleFlag: { GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION: 16 },
      getBundleInfoForSelfSync: () => ({ reqPermissionDetails: declared ? [{ name: 'ohos.permission.FLOAT_VIEW' }] : [] })
    }, abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager: () => ({
      requestPermissionsFromUser: async () => {
        if (holdPermission) await permissionGate;
        return { authResults: [granted ? 0 : -1] };
      }
    }) } },
    '@kit.BasicServicesKit': { deviceInfo: { apiAvailable: () => native } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => ({ width: 1320, height: 2760, densityPixels: 3.5 }) },
      floatView: { isFloatViewEnabled: () => true, create: async () => { calls.push('native-create'); return controller; },
        getFloatViewLimits: () => ({ minSize: { width: 200, height: 150 }, maxSize: { width: 1200, height: 1100 } }),
        FloatViewTemplateType: { ROUNDED_RECTANGLE: 0 },
        FloatViewState: { STARTED: 'started', STOPPED: 'stopped', HIDDEN: 'hidden', IN_SIDEBAR: 'sidebar', ERROR: 'error' } } }
  }, store, timers).PostureFloatService;
  service.initialize({ createSubWindow: async () => child });
  return { service, store, calls, timers, releasePermission, releaseContent,
    event: state => stateChange({ state }), started: () => stateChange({ state: 'started' }) };
}

async function verify() {
  const legacy = fixture();
  await legacy.service.open({});
  assert.equal(legacy.store.get('floatNative'), false);
  assert.equal(legacy.store.get('floatVisible'), true);
  assert.ok(legacy.store.get('floatMessage').includes('应用内'));
  await legacy.service.open({});
  assert.equal(legacy.calls.filter(v => v === 'child-show').length, 1);
  legacy.service.move();
  await legacy.service.background();
  assert.equal(legacy.store.get('floatVisible'), false);
  assert.ok(legacy.calls.includes('child-destroy'));

  const denied = fixture({ native: true, granted: false });
  await denied.service.open({});
  assert.equal(denied.store.get('floatVisible'), false);
  assert.ok(!denied.calls.includes('native-create'));

  const undeclared = fixture({ native: true, declared: false });
  await undeclared.service.open({});
  assert.equal(undeclared.store.get('floatNative'), false);
  assert.ok(!undeclared.calls.includes('native-create'));

  const native = fixture({ native: true });
  await native.service.open({});
  assert.equal(native.store.get('floatVisible'), false, 'start() resolution is not a STARTED callback');
  assert.equal(native.store.get('floatBusy'), true);
  native.event('hidden');
  assert.equal(native.store.get('floatVisible'), false, 'Only STARTED confirms creation');
  assert.equal(native.store.get('floatBusy'), true);
  await native.service.open({});
  assert.equal(native.calls.filter(v => v === 'native-create').length, 1);
  native.started();
  assert.equal(native.store.get('floatVisible'), true);
  assert.equal(native.store.get('floatBusy'), false);
  assert.equal(native.store.get('floatAvoidTop'), 72);
  native.event('sidebar');
  assert.equal(native.store.get('floatState'), 'sidebar');
  assert.equal(native.store.get('floatVisible'), true);
  native.event('hidden');
  assert.equal(native.store.get('floatState'), 'hidden');
  await native.service.background();
  assert.equal(native.store.get('floatVisible'), true, 'Native status window may remain visible in background');
  await native.service.close();
  assert.equal(native.store.get('floatVisible'), false);
  assert.equal(native.timers.size, 0);

  const restored = fixture({ native: true });
  await restored.service.open({});
  restored.started();
  await restored.service.restore({ startAbility: async () => { throw new Error('Use native restore API'); } });
  assert.deepEqual(restored.calls.slice(-2), ['restore-native', 'native-stop']);

  const legacyRestore = fixture();
  await legacyRestore.service.open({});
  await legacyRestore.service.restore({ startAbility: async () => legacyRestore.calls.push('restore-child') });
  assert.deepEqual(legacyRestore.calls.slice(-2), ['restore-child', 'child-destroy']);

  const earlyClose = fixture({ native: true });
  await earlyClose.service.open({});
  await earlyClose.service.close();
  earlyClose.started();
  assert.equal(earlyClose.store.get('floatVisible'), false);

  const failed = fixture({ native: true, fail: true });
  await failed.service.open({});
  assert.equal(failed.store.get('floatVisible'), false);
  assert.ok(failed.store.get('floatMessage').includes('未能开启'));
  assert.equal(failed.store.get('floatBusy'), false);
  assert.equal(failed.timers.size, 0);

  for (const hold of ['holdPermission', 'holdContent']) {
    const interrupted = fixture({ native: true, [hold]: true });
    const pending = interrupted.service.open({});
    await Promise.resolve();
    await Promise.resolve();
    await interrupted.service.close();
    interrupted.releasePermission();
    interrupted.releaseContent();
    await pending;
    assert.ok(!interrupted.calls.includes('native-start'), hold + ' must cancel before starting');
    assert.equal(interrupted.store.get('floatBusy'), false);
    assert.equal(interrupted.store.get('floatVisible'), false);
    assert.equal(interrupted.store.get('floatState'), 'idle');
  }
  const timedOut = fixture({ native: true });
  await timedOut.service.open({});
  timedOut.timers.values().next().value();
  await Promise.resolve();
  assert.equal(timedOut.store.get('floatVisible'), false);
  assert.equal(timedOut.store.get('floatBusy'), false);

  const stoppedBySystem = fixture({ native: true });
  await stoppedBySystem.service.open({});
  stoppedBySystem.started();
  stoppedBySystem.event('error');
  assert.equal(stoppedBySystem.store.get('floatState'), 'error');
  assert.equal(stoppedBySystem.store.get('floatVisible'), false);
  await stoppedBySystem.service.open({});
  assert.equal(stoppedBySystem.calls.filter(v => v === 'native-create').length, 2);
  stoppedBySystem.started();
  await stoppedBySystem.service.close();

  const closeFailed = fixture({ native: true, stopFails: true });
  await closeFailed.service.open({});
  closeFailed.started();
  await closeFailed.service.close();
  assert.equal(closeFailed.store.get('floatVisible'), true, 'Cannot claim a failed close succeeded');
  assert.equal(closeFailed.store.get('floatBusy'), false);

  const stopping = fixture({ native: true, deferStop: true });
  await stopping.service.open({});
  stopping.started();
  await stopping.service.close();
  stopping.event('hidden');
  stopping.started();
  assert.equal(stopping.store.get('floatState'), 'closing');
  assert.equal(stopping.store.get('floatBusy'), true);
  assert.equal(stopping.timers.size, 1, 'Intermediate events must not clear the stop deadline');
  stopping.event('stopped');
  assert.equal(stopping.store.get('floatVisible'), false);
  assert.equal(stopping.store.get('floatBusy'), false);
  assert.equal(stopping.timers.size, 0);

  const brightnessCalls = [];
  const mainWindow = {
    getWindowProperties: () => ({ brightness: -1 }),
    setWindowKeepScreenOn: async value => brightnessCalls.push(['keep', value]),
    setWindowBrightness: async value => brightnessCalls.push(['brightness', value])
  };
  const GuardWindow = load('GuardWindowService.ets', {
    '@kit.AbilityKit': {}, '@ohos.base': {},
    '@kit.PerformanceAnalysisKit': { hilog: { info: () => {}, warn: () => {} } },
    '@kit.ArkUI': { window: { getLastWindow: async () => { throw new Error('Must not target floating window'); } } }
  }, new Map()).GuardWindowService;
  GuardWindow.setMainWindow(mainWindow);
  const guardWindow = new GuardWindow();
  await guardWindow.enter({});
  await guardWindow.leave({});
  assert.deepEqual(brightnessCalls, [['keep', true], ['brightness', 0.18], ['keep', false], ['brightness', -1]]);
  console.log('PASS: float permission, sizing, avoid area, pending/cancel/timeout/error/sidebar/hidden/restore flows and no duplicate windows');
  console.log('PASS: child-window fallback, failed-close honesty and main-window brightness restoration');
  console.log('NOTE: mocked SDK contract tests; not device rendering or cross-app validation');
}
verify().catch(error => { console.error(error); process.exitCode = 1; });
