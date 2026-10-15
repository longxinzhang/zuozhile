#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const root = path.resolve(__dirname, '..');
const ts = require('./deveco-sdk.cjs').typescript;
const read = file => fs.readFileSync(path.join(root, file), 'utf8');
const parseOptions = {
  ets: {
    render: { method: ['build'], decorator: ['Builder'] },
    components: ['Stack', 'Column', 'Row', 'Canvas', 'Navigation', 'Tabs', 'TabContent', 'Text', 'Button',
      'Slider', 'Toggle', 'Progress', 'Scroll', 'List', 'ListItem', 'XComponent', 'SymbolGlyph',
      'LoadingProgress', 'Divider', 'Image', 'Blank', 'Grid', 'GridItem', 'RelativeContainer', 'LowScoreEdgeLight'],
    libs: [],
    extend: { decorator: [], components: [] },
    styles: {
      decorator: 'Styles',
      component: { name: 'Common', type: 'CommonAttribute', instance: 'CommonInstance' },
      property: '__style__'
    },
    concurrent: { decorator: 'Concurrent' },
    propertyDecorators: [],
    emitDecorators: [],
    syntaxComponents: { paramsUICallback: ['ForEach', 'LazyForEach'], attrUICallback: [] }
  }
};
const printer = ts.createPrinter({ removeComments: true });
let checks = 0;
const pass = name => { checks++; console.log('PASS: ' + name); };
function parse(file, text = read(file)) {
  const ast = ts.createSourceFile(file, text, ts.ScriptTarget.Latest, true, ts.ScriptKind.ETS, parseOptions);
  assert.deepEqual(Array.from(ast.parseDiagnostics, diagnostic => ts.flattenDiagnosticMessageText(diagnostic.messageText, '\n')),
    [], file + ' must parse with the actual ArkTS SDK');
  return ast;
}
function load(file, mocks, globals = {}) {
  const source = parse('entry/src/main/ets/' + file + '.ets');
  const module = { exports: {} };
  const runtime = ts.transpileModule(printer.printFile(source), {
    fileName: file + '.ts', reportDiagnostics: true,
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  });
  assert.equal(runtime.diagnostics.length, 0, file + ' runtime extraction must transpile');
  vm.runInNewContext(runtime.outputText, { module, exports: module.exports, ...globals, require: name => {
    if (Object.hasOwn(mocks, name)) return mocks[name];
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
  pass('appearance defaults, bounds, separate storage, serialized rapid changes, error reporting and retry');

  const ast = parse('entry/src/main/ets/pages/Index.ets');
  const page = ast.statements.find(node => ts.isStructDeclaration(node) && node.name.text === 'Index');
  assert.ok(page, 'Use the actual Index struct without rewriting ArkTS into TypeScript');
  const setter = printer.printNode(ts.EmitHint.Unspecified,
    page.members.find(node => node.name?.getText(ast) === 'setImmersiveLevel'), ast);
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
  pass('live selection, stale completion isolation, failed-save retry and calibration/busy lock');

  const colorsFor = dark => Object.fromEntries(JSON.parse(read(`entry/src/main/resources/${dark ? 'dark' : 'base'}/element/color.json`))
    .color.map(item => [item.name, item.value]));
  const calls = [];
  const storage = new Map();
  const writes = [];
  const warnings = [];
  const floatCalls = [];
  const guardWindows = [];
  const ability = load('entryability/EntryAbility', {
    '@kit.AbilityKit': { UIAbility: class {}, ConfigurationConstant: {
      ColorMode: { COLOR_MODE_DARK: 0, COLOR_MODE_LIGHT: 1, COLOR_MODE_NOT_SET: -1 }
    } },
    '@kit.ArkUI': { window: {} },
    '@kit.PerformanceAnalysisKit': { hilog: { warn: (...args) => warnings.push(args), info() {}, error() {} } },
    '../services/PostureFloatService': { PostureFloatService: {
      initialize: stage => floatCalls.push(['initialize', stage]),
      close: () => floatCalls.push(['close']), background: () => floatCalls.push(['background'])
    } },
    '../services/GuardWindowService': { GuardWindowService: { setMainWindow: window => guardWindows.push(window) } },
    '../services/ARFaceCapability': { supportsFaceTracking: () => false },
    '../services/AppearanceStore': { AppearanceStore: { load: async () => ({ level: 3, isHealthy: true }) } }
  }, { AppStorage: { setOrCreate(key, value) { storage.set(key, value); writes.push([key, value]); } } });
  const instance = new ability.default();
  const colorModes = [];
  instance.context = { config: { colorMode: 1 },
    getApplicationContext: () => ({ setColorMode: mode => colorModes.push(mode) }) };
  instance.mainWindow = { setWindowSystemBarProperties: async options => calls.push(options) };
  const checkBars = dark => {
    const colors = colorsFor(dark), bars = calls.at(-1);
    assert.deepEqual({ ...bars }, {
      statusBarColor: '#00000000', navigationBarColor: '#00000000',
      statusBarContentColor: colors.ink, navigationBarContentColor: colors.ink
    });
    assert.notEqual(bars.statusBarColor, colors.app_bg);
    assert.notEqual(bars.navigationBarColor, colors.app_bg);
    assert.equal(storage.get('appColorMode'), dark ? 0 : 1);
    assert.deepEqual(writes.at(-1), ['appColorMode', dark ? 0 : 1]);
  };
  for (const dark of [false, true, false]) {
    const before = calls.length;
    instance.onConfigurationUpdate({ colorMode: dark ? 0 : 1 });
    assert.equal(calls.length, before + 1);
    checkBars(dark);
  }
  instance.context.config.colorMode = 0;
  instance.onConfigurationUpdate({});
  checkBars(true);
  instance.onForeground();
  assert.equal(storage.get('appForeground'), true);
  assert.equal(storage.get('appColorMode'), 0);
  assert.equal(calls.at(-1).statusBarContentColor, colorsFor(true).ink);
  instance.onBackground();
  assert.equal(storage.get('appForeground'), false);
  assert.deepEqual(floatCalls.at(-1), ['background']);
  instance.mainWindow = undefined;
  const noWindowCalls = calls.length;
  instance.onConfigurationUpdate({ colorMode: 1 });
  assert.equal(storage.get('appColorMode'), 1);
  assert.equal(calls.length, noWindowCalls);
  instance.onCreate({}, {});
  await Promise.resolve();
  assert.deepEqual(colorModes, [-1]);
  assert.equal(storage.get('appearanceReady'), true);
  assert.equal(storage.get('immersiveLevel'), 3);
  pass('transparent status/navigation bars keep themed foregrounds and publish appColorMode on updates/foreground');

  function windowFixture(options = {}) {
    let rect = { left: 0, top: 0, width: 1320, height: 2760 };
    let resolveLayout, rejectLayout;
    const layout = new Promise((resolve, reject) => { resolveLayout = resolve; rejectLayout = reject; });
    const layouts = [], registrations = [], removals = [], contents = [];
    const listeners = new Map();
    const mainWindow = {
      setWindowLayoutFullScreen(value) { layouts.push(value); return layout; },
      getWindowProperties: () => ({ windowRect: { ...rect } }),
      setWindowSystemBarProperties: async properties => calls.push(properties),
      on(event, listener) { registrations.push([event, listener]); listeners.set(event, listener); },
      off(event, listener) {
        removals.push([event, listener]);
        if (options.failOff) throw Error('cleanup failure');
        assert.equal(listeners.get(event), listener);
        listeners.delete(event);
      }
    };
    const stage = { getMainWindowSync: () => mainWindow,
      loadContent(route, callback) { contents.push(route); callback({ code: 0 }); } };
    const subject = new ability.default();
    subject.context = { config: { colorMode: 1 } };
    const start = () => subject.onWindowStageCreate(stage);
    const emitSize = (width, height) => {
      rect = { ...rect, width, height };
      listeners.get('windowSizeChange')?.({ width, height });
    };
    const resolve = async (width, height) => {
      rect = { ...rect, width, height };
      resolveLayout();
      await layout;
      await Promise.resolve();
    };
    const reject = async () => {
      rejectLayout(Error('layout unavailable'));
      await layout.catch(() => {});
      await Promise.resolve();
    };
    return { subject, stage, mainWindow, layouts, registrations, removals, contents, listeners,
      start, emitSize, resolve, reject };
  }

  const screen = windowFixture();
  screen.start();
  assert.deepEqual(screen.layouts, [true]);
  assert.equal(screen.subject.mainWindow, screen.mainWindow);
  assert.equal(screen.registrations.length, 1);
  assert.equal(screen.registrations[0][0], 'windowSizeChange');
  assert.equal(screen.registrations[0][1], screen.subject.windowSizeListener);
  assert.deepEqual(screen.contents, ['pages/Index'], 'The content route is unchanged');
  assert.equal(guardWindows.at(-1), screen.mainWindow);
  assert.equal(floatCalls.at(-1)[0], 'initialize');
  assert.equal(floatCalls.at(-1)[1], screen.stage);
  const checkSize = (width, height) => {
    assert.equal(storage.get('glowWindowWidthPx'), width);
    assert.equal(storage.get('glowWindowHeightPx'), height);
    assert.deepEqual(writes.slice(-2), [['glowWindowWidthPx', width], ['glowWindowHeightPx', height]]);
  };
  assert.equal(storage.get('glowWindowWidthPx'), 1320);
  assert.equal(storage.get('glowWindowHeightPx'), 2760);
  checkBars(false);
  screen.emitSize(2760, 1320);
  checkSize(2760, 1320);
  screen.emitSize(1320, 2760);
  checkSize(1320, 2760);
  await screen.resolve(2760, 1320);
  checkSize(2760, 1320);
  screen.subject.onWindowStageDestroy();
  assert.equal(screen.removals.length, 1);
  assert.equal(screen.removals[0][0], 'windowSizeChange');
  assert.equal(screen.removals[0][1], screen.registrations[0][1]);
  assert.equal(screen.listeners.size, 0);
  assert.equal(screen.subject.mainWindow, undefined);
  assert.deepEqual(floatCalls.at(-1), ['close']);
  const afterDestroy = writes.length;
  screen.emitSize(1320, 2760);
  assert.equal(writes.length, afterDestroy);
  pass('full-screen layout publishes the complete 1320x2760/2760x1320 rect, preserves content and pairs size on/off');

  const destroyed = windowFixture();
  destroyed.start();
  destroyed.subject.onWindowStageDestroy();
  const beforeLateLayout = writes.length;
  await destroyed.resolve(800, 600);
  assert.equal(writes.length, beforeLateLayout, 'Late full-screen completion cannot publish a destroyed window');
  const unavailable = windowFixture();
  unavailable.start();
  await unavailable.reject();
  assert.deepEqual(unavailable.contents, ['pages/Index']);
  assert.ok(warnings.some(args => args[2] === 'Full-screen glow layout unavailable'));
  unavailable.emitSize(2760, 1320);
  checkSize(2760, 1320);
  unavailable.subject.onWindowStageDestroy();
  const cleanupFailure = windowFixture({ failOff: true });
  cleanupFailure.start();
  cleanupFailure.subject.onWindowStageDestroy();
  assert.equal(cleanupFailure.subject.mainWindow, undefined);
  assert.deepEqual(floatCalls.at(-1), ['close']);
  const beforeCleanupCompletion = writes.length;
  await cleanupFailure.resolve(800, 600);
  assert.equal(writes.length, beforeCleanupCompletion);
  assert.ok(warnings.some(args => args[2] === 'Window size listener cleanup failed'));
  pass('full-screen failure retains content/size updates, late completion is isolated and off failure still closes services');

  function bodyNavigation(source) {
    const struct = source.statements.find(node => ts.isStructDeclaration(node) && node.name.text === 'Index');
    const build = struct.members.find(node => node.name?.getText(source) === 'build');
    const navigation = [];
    const visit = node => {
      if (ts.isEtsComponentExpression(node) && node.expression.getText(source) === 'Navigation') navigation.push(node);
      ts.forEachChild(node, visit);
    };
    visit(build.body);
    assert.equal(navigation.length, 1);
    const attrs = new Map();
    let expression = navigation[0];
    while (ts.isPropertyAccessExpression(expression.parent) && expression.parent.expression === expression &&
      ts.isCallExpression(expression.parent.parent)) {
      const call = expression.parent.parent;
      attrs.set(expression.parent.name.text, call.arguments);
      expression = call;
    }
    return { expression, attrs };
  }
  const { expression: content, attrs } = bodyNavigation(ast);
  const baseline = parse('entry/src/main/ets/pages/Index.ets', execFileSync('git',
    ['show', 'd73d591:entry/src/main/ets/pages/Index.ets'], { cwd: root, encoding: 'utf8' }));
  assert.equal(printer.printNode(ts.EmitHint.Unspecified, content, ast),
    printer.printNode(ts.EmitHint.Unspecified, bodyNavigation(baseline).expression, baseline),
    'The full body Navigation subtree must remain unchanged from the accepted 0.2.7 baseline');
  assert.equal(attrs.get('backgroundColor')?.[0].getText(ast), 'APP_BG', 'Only system bar backgrounds become transparent');
  assert.equal(attrs.get('width')?.[0].text, '100%');
  assert.equal(attrs.get('height')?.[0].text, '100%');
  assert.equal(attrs.has('expandSafeArea'), false, 'The glow does not expand the body navigation into system bars');
  assert.equal(attrs.has('padding'), false, 'Full-screen glow must not add body insets');
  assert.equal(attrs.has('ignoreLayoutSafeArea'), false, 'Only the glow host may ignore body safe areas');
  const glowNodes = [];
  const visitGlow = node => {
    if (ts.isEtsComponentExpression(node) && node.expression.getText(ast) === 'LowScoreEdgeLight') glowNodes.push(node);
    ts.forEachChild(node, visitGlow);
  };
  visitGlow(page.members.find(node => node.name?.getText(ast) === 'build').body);
  assert.equal(glowNodes.length, 1, 'Preview and guarding share one root glow host');
  const hostAttrs = new Map();
  const glowHost = glowNodes[0].parent.parent.parent;
  assert.ok(ts.isEtsComponentExpression(glowHost), 'The glow must be directly enclosed by a layout host');
  assert.equal(glowHost.expression.getText(ast), 'Stack');
  assert.equal(glowHost.arguments[0].properties[0].name.getText(ast), 'alignContent');
  assert.equal(glowHost.arguments[0].properties[0].initializer.getText(ast), 'Alignment.TopStart');
  let host = glowHost;
  while (ts.isPropertyAccessExpression(host.parent) && host.parent.expression === host &&
    ts.isCallExpression(host.parent.parent)) {
    const call = host.parent.parent;
    hostAttrs.set(host.parent.name.text, call.arguments);
    host = call;
  }
  assert.equal(hostAttrs.get('width')?.[0].getText(ast), 'LayoutPolicy.matchParent');
  assert.equal(hostAttrs.get('height')?.[0].getText(ast), 'LayoutPolicy.matchParent');
  assert.equal(hostAttrs.get('align')?.[0].getText(ast), 'Alignment.TopStart');
  assert.deepEqual(Array.from(hostAttrs.get('ignoreLayoutSafeArea')[0].elements, node => node.getText(ast)),
    ['LayoutSafeAreaType.SYSTEM']);
  assert.deepEqual(Array.from(hostAttrs.get('ignoreLayoutSafeArea')[1].elements, node => node.getText(ast)),
    ['LayoutSafeAreaEdge.ALL']);
  assert.equal(hostAttrs.get('hitTestBehavior')?.[0].getText(ast), 'HitTestMode.None');
  assert.equal(hostAttrs.get('accessibilityLevel')?.[0].text, 'no');
  assert.equal(hostAttrs.get('id')?.[0].text, 'low-score-glow-host');
  for (const attr of ['expandSafeArea', 'padding', 'margin', 'clip', 'border', 'backgroundColor']) {
    assert.equal(hostAttrs.has(attr), false, 'The glow host cannot inset, clip or cover the body: ' + attr);
  }
  pass('body Navigation matches 0.2.7 while the single noninteractive glow host expands its layout at all screen edges');

  const lightNames = JSON.parse(read('entry/src/main/resources/base/element/color.json')).color.map(c => c.name).sort();
  const darkNames = JSON.parse(read('entry/src/main/resources/dark/element/color.json')).color.map(c => c.name).sort();
  assert.deepEqual(lightNames, darkNames);
  assert.equal(new Set(lightNames).size, lightNames.length);
  pass('complete matching light/dark resource keys without duplicates');
  console.log(`PASS: ${checks} appearance offline test groups; ${calls.length} system bar updates; ${writes.length} storage writes; 0 failures`);
}
main().catch(error => { console.error(error); process.exitCode = 1; });
