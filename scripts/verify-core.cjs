#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');

const root = path.resolve(__dirname, '..');
const baseline = process.argv[2] || 'fac06c8';
const sdkRoot = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app';
const ts = require(path.join(sdkRoot,
  'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const sourceRoot = 'entry/src/main/ets/';
const now = Date.UTC(2026, 8, 22, 8);
class TestDate extends Date {
  constructor(value = now) { super(value); }
  static now() { return now; }
}

function source(file, previous) {
  return previous
    ? execFileSync('git', ['show', `${baseline}:${file}`], { cwd: root, encoding: 'utf8' })
    : fs.readFileSync(path.join(root, file), 'utf8');
}

const protectedFiles = [
  'models/ReminderEngine.ets', 'models/SessionStats.ets',
  'services/CoreVisionPostureSource.ets', 'services/PostureSessionStore.ets'
];
for (const name of protectedFiles) {
  assert.equal(source(sourceRoot + name, false), source(sourceRoot + name, true), `${name} changed`);
}

// Explicitly authorized changes: automatic calibration, lifecycle cleanup, unavailable mouth data.
const protectedMethods = ['captureFrame', 'applyResult', 'appendRecord',
  'shouldAdoptMetric', 'setSensitivity', 'setIntervalMs', 'buildSessionReport'];
function pageMethod(previous, name) {
  const text = source(sourceRoot + 'pages/Index.ets', previous).replace('struct Index {', 'class Index {');
  const tree = ts.createSourceFile('Index.ts', text, ts.ScriptTarget.Latest, true);
  const page = tree.statements.find((node) => ts.isClassDeclaration(node) && node.name.text === 'Index');
  const member = page.members.find((node) => node.name && node.name.getText(tree) === name);
  assert.ok(member, `Missing protected page method ${name}`);
  return member.getText(tree);
}
for (const name of protectedMethods) {
  assert.equal(pageMethod(false, name), pageMethod(true, name), `${name} changed`);
}
function declarations(file, previous) {
  const tree = ts.createSourceFile(file, source(sourceRoot + file, previous), ts.ScriptTarget.Latest, true);
  return new Map(tree.statements.filter(ts.isFunctionDeclaration).map(node => [node.name.text, node.getText(tree)]));
}
const oldRules = declarations('models/PostureEvaluator.ets', true);
const newRules = declarations('models/PostureEvaluator.ets', false);
for (const [name, body] of oldRules) {
  if (!['evaluateMouth', 'evaluatePosture'].includes(name)) {
    assert.equal(newRules.get(name), body, `Posture rule ${name} changed`);
  }
}
assert.equal(declarations('models/PostureCalibration.ets', false).get('inspectCalibrationSamples'),
  declarations('models/PostureCalibration.ets', true).get('inspectCalibrationSamples'));

// Compare actual rule execution against the last shipped version with identical clocks and samples.
function loader(previous) {
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    const compiled = ts.transpileModule(source(file, previous), {
      compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
    }).outputText;
    const module = { exports: {} };
    cache.set(file, module);
    vm.runInNewContext(compiled, {
      module, exports: module.exports, Date: TestDate, console,
      require: (name) => {
        assert.ok(name.startsWith('.'), `Unexpected native dependency: ${name}`);
        return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name + '.ets')));
      }
    }, { filename: file });
    return module.exports;
  }
  return (file) => load(sourceRoot + file + '.ets');
}
const before = loader(true);
const after = loader(false);
const types = before('models/PostureTypes');
const generate = before('services/MockFrameSampler').createSimulatedSample;
const oldEvaluate = before('models/PostureEvaluator').evaluatePosture;
const newEvaluate = after('models/PostureEvaluator').evaluatePosture;
const normalize = (value) => JSON.parse(JSON.stringify(value));
const variants = [
  (s) => s,
  (s) => { s.face.confidence = 0; return s; },
  (s) => { s.skeleton = {}; return s; },
  (s) => { s.face.pitch = -40; return s; },
  (s) => { s.face.roll = 25; return s; },
  (s) => { s.face.yaw = 65; return s; },
  (s) => { s.face.mouthOpenRatio = 0.65; return s; },
  (s) => { s.skeleton.leftShoulder.score = 0.1; return s; }
];
let evaluations = 0;
let reminders = 0;
for (const sensitivity of [types.STANDARD_SENSITIVITY, types.SENSITIVE_SENSITIVITY]) {
  for (const sampleIntervalMs of [2000, 3000, 5000]) {
    const profile = { ...types.createDefaultCalibration(), sensitivity, sampleIntervalMs };
    const oldEngine = new (before('models/ReminderEngine').ReminderEngine)();
    const newEngine = new (after('models/ReminderEngine').ReminderEngine)();
    const records = [];
    for (let tick = 0; tick < 420; tick++) {
      const sample = generate(Math.floor(tick / 5), profile);
      sample.timestamp = now + tick * sampleIntervalMs;
      for (const variant of variants) {
        const frame = variant(normalize(sample));
        assert.deepEqual(normalize(newEvaluate(frame, profile)), normalize(oldEvaluate(frame, profile)),
          `Evaluation drift at tick ${tick}, sensitivity ${sensitivity}, interval ${sampleIntervalMs}`);
        evaluations++;
      }
      const oldResult = oldEvaluate(sample, profile);
      const newResult = newEvaluate(sample, profile);
      const oldAction = oldEngine.feed(oldResult, sample.timestamp);
      const newAction = newEngine.feed(newResult, sample.timestamp);
      assert.equal(newAction, oldAction);
      assert.equal(newEngine.alertType(), oldEngine.alertType());
      reminders++;
      records.push({ timestamp: sample.timestamp, score: newResult.score,
        sitLevel: newResult.sit.level, chinLevel: newResult.chin.level,
        mouthLevel: newResult.mouth.level, action: newAction, alertType: newEngine.alertType() });
    }
    assert.deepEqual(normalize(after('models/SessionStats').computeTodayStats(records, sampleIntervalMs)),
      normalize(before('models/SessionStats').computeTodayStats(records, sampleIntervalMs)));
    for (const count of [0, 3, 5, 10]) {
      const samples = Array.from({ length: count }, (_, n) => generate(n % 5, profile));
      for (const method of ['inspectCalibrationSamples', 'buildCalibrationProfile']) {
        assert.deepEqual(normalize(after('models/PostureCalibration')[method](samples, profile)),
          normalize(before('models/PostureCalibration')[method](samples, profile)));
      }
    }
  }
}
console.log(`PASS: ${protectedFiles.length} core files unchanged from ${baseline}`);
console.log(`PASS: ${protectedMethods.length} sampling, calibration, reminder and session methods unchanged`);
console.log(`PASS: ${evaluations} evaluations, ${reminders} reminder decisions, calibration and daily stats match`);

for (let tick = 0; tick < 420; tick++) {
  const profile = types.createDefaultCalibration();
  const sample = generate(tick, profile);
  const original = newEvaluate(sample, profile);
  sample.face.mouthAvailable = false;
  sample.face.mouthOpenRatio = 0.95;
  const result = newEvaluate(sample, profile);
  assert.deepEqual(normalize(result.sit), normalize(original.sit));
  assert.deepEqual(normalize(result.chin), normalize(original.chin));
  assert.equal(result.mouth.level, types.PostureLevel.UNKNOWN);
  assert.equal(result.mouth.alertType, types.PostureAlertType.NONE);
  assert.equal(result.score, Math.round((result.sit.score * .4 + result.chin.score * .45) / .85));
  assert.ok(!result.activeAlerts.includes(types.PostureAlertType.ITEM_11));
}
const mouthBaseline = types.createDefaultCalibration();
const withoutMouth = Array.from({ length: 5 }, () => {
  const sample = generate(0, mouthBaseline);
  sample.face.mouthAvailable = false;
  sample.face.mouthOpenRatio = 0;
  return sample;
});
assert.equal(after('models/PostureCalibration').buildCalibrationProfile(withoutMouth, mouthBaseline).neutralMouthRatio,
  mouthBaseline.neutralMouthRatio);
const detector = source(sourceRoot + 'services/CoreVisionPostureDetector.ets', false);
assert.ok(!detector.includes('estimateMouthRatio'));
assert.equal((detector.match(/mouthAvailable: false/g) || []).length, 3);
console.log('PASS: unavailable mouth is explicit, excluded from score and baseline; sit/chin rules unchanged');

// Exercise display-only states separately from the unchanged detection rules.
assert.match(pageMethod(false, 'lastSample'), /^@State\s+@Watch\('syncFloatingState'\)\s+private lastSample/,
  'The first sample must invalidate waiting-state builders');
for (const [file, components] of [
  ['components/PostureMetricTile.ets', ['PostureMetricTile']],
  ['components/StatusTiles.ets', ['StatTile', 'SmallCounter', 'BaselineTile']]
]) {
  const tree = ts.createSourceFile(file, source(sourceRoot + file, false).replace(/\bstruct\b/g, 'class'),
    ts.ScriptTarget.Latest, true);
  for (const name of components) {
    const component = tree.statements.find((node) => ts.isClassDeclaration(node) && node.name.text === name);
    assert.ok(component, `Missing ${name}`);
    for (const member of component.members.filter(ts.isPropertyDeclaration)) {
      assert.match(member.getText(tree), /^@Prop\s/, `${name}.${member.name.getText(tree)} must stay reactive`);
    }
  }
}
assert.ok(!pageMethod(false, 'MetricGrid').includes('this.MetricTile('),
  'Metric values must not be frozen in a pass-by-value builder');
console.log('PASS: metric, statistics and baseline components preserve reactive input bindings');
const uiMethods = ['isFinishedUiState', 'isIdleUiState', 'hasCurrentReading', 'isUnrecognizedUiState', 'heroScoreText',
  'isDetectionErrorUiState', 'headerStatusText', 'headerSwitchText', 'retryDetection',
  'heroProgressValue', 'heroTitleText', 'heroDetailText', 'heroStatusLabel', 'intervalLabel'];
const uiSource = `class PreviewState { ${uiMethods.map((name) => pageMethod(false, name)).join('\n')} }
new PreviewState();`;
const ui = vm.runInNewContext(ts.transpileModule(uiSource, {
  compilerOptions: { target: ts.ScriptTarget.ES2020 }
}).outputText, { ReminderAction: types.ReminderAction, PostureLevel: types.PostureLevel });
Object.assign(ui, { isGuarding: false, isStartingGuard: false, isStoppingGuard: false,
  sessionReportTitle: '', summary: '坐姿在线', score: 92, sessionReportScore: 0,
  reminderAction: types.ReminderAction.NONE, guardSessionStartedAt: 100,
  settings: { profile: { sampleIntervalMs: 3000 } }, lastSampleText: '08:00:00',
  sitLevel: types.PostureLevel.GOOD, chinLevel: types.PostureLevel.GOOD, mouthLevel: types.PostureLevel.GOOD });
assert.equal(ui.heroScoreText(), '--');
assert.equal(ui.heroProgressValue(), 0);
ui.isGuarding = true;
ui.lastSample = { timestamp: 99 };
assert.equal(ui.heroScoreText(), '--');
assert.equal(ui.heroTitleText(), '正在准备检测');
assert.equal(ui.heroStatusLabel(), '等待采样');
assert.ok(ui.heroDetailText().startsWith('等待首次采样'));
ui.lastSample = { timestamp: 100 };
assert.equal(ui.heroScoreText(), '92');
assert.equal(ui.heroProgressValue(), 92);
assert.equal(ui.heroTitleText(), '坐姿在线');
assert.equal(ui.heroStatusLabel(), '状态良好');
ui.sitLevel = ui.chinLevel = ui.mouthLevel = types.PostureLevel.UNKNOWN;
assert.equal(ui.heroScoreText(), '--');
assert.equal(ui.heroProgressValue(), 0);
assert.equal(ui.heroTitleText(), '未看清姿态');
assert.equal(ui.heroStatusLabel(), '等待入镜');
ui.isGuarding = false;
ui.summary = '需要相机权限';
assert.equal(ui.heroTitleText(), '需要相机权限');
assert.equal(ui.heroScoreText(), '--');
ui.summary = '坐姿在线';
ui.sessionReportTitle = '本次守护报告';
ui.sessionReportScore = 80;
assert.equal(ui.heroScoreText(), '80');
assert.equal(ui.heroProgressValue(), 80);
assert.equal(ui.heroTitleText(), '本次守护已结束');
ui.summary = '采样失败';
assert.equal(ui.heroTitleText(), '本次守护已结束');
assert.equal(ui.heroStatusLabel(), '已生成报告');
assert.equal(ui.heroScoreText(), '80');
ui.sessionReportTitle = '';
ui.isGuarding = true;
for (const summary of ['采样失败', '相机不可用', '预览未就绪', '需要相机权限']) {
  ui.summary = summary;
  for (const level of [types.PostureLevel.GOOD, types.PostureLevel.UNKNOWN]) {
    ui.sitLevel = ui.chinLevel = ui.mouthLevel = level;
    assert.equal(ui.isDetectionErrorUiState(), true);
    assert.equal(ui.heroScoreText(), '--');
    assert.equal(ui.heroProgressValue(), 0);
    assert.equal(ui.heroStatusLabel(), '等待恢复');
    assert.equal(ui.headerStatusText(), '检测暂不可用');
    assert.equal(ui.headerSwitchText(), '待恢复');
  }
}
ui.isStartingGuard = true;
assert.equal(ui.isDetectionErrorUiState(), false);
assert.equal(ui.heroTitleText(), '正在准备检测');
console.log('PASS: idle, waiting, stale frame, first frame, unrecognized, errors and report display states');

async function verifyRecovery() {
  const calls = [];
  ui.pageRunId = 1;
  ui.isCurrentPageRun = (id) => id === ui.pageRunId;
  ui.controlsLocked = () => false;
  ui.stopGuard = async (updateUi, report) => { calls.push(['stop', updateUi, report]); };
  ui.startGuard = async () => { calls.push(['start']); };
  ui.isGuarding = true;
  await ui.retryDetection();
  assert.deepEqual(calls, [['stop', true, false], ['start']]);
  assert.equal(ui.summary, '正在准备检测');
  calls.length = 0;
  ui.isGuarding = false;
  await ui.retryDetection();
  assert.deepEqual(calls, [['start']]);
  calls.length = 0;
  ui.controlsLocked = () => true;
  await ui.retryDetection();
  assert.deepEqual(calls, []);
  ui.controlsLocked = () => false;
  ui.isGuarding = true;
  ui.stopGuard = async () => { ui.pageRunId++; };
  await ui.retryDetection();
  assert.deepEqual(calls, []);
  ui.isGuarding = false;
  ui.startGuard = async () => { throw new Error('camera unavailable'); };
  await ui.retryDetection();
  assert.equal(ui.summary, '相机不可用');
  console.log('PASS: recovery ordering, idle retry, busy lock, page disposal and recovery failure');
}
async function verifyNewFlows() {
  await verifyRecovery();
  const capture = after('models/CalibrationCapture').captureCalibration;
  let completed = [];
  let calls = 0;
  const healthy = async () => { calls++; return generate(0, mouthBaseline); };
  const progress = (n, total) => completed.push([n, total]);
  assert.equal((await capture(healthy, () => false, progress, 5)).isUsable, true);
  assert.equal(calls, 5);
  assert.deepEqual(completed, [[1,5],[2,5],[3,5],[4,5],[5,5]]);
  calls = 0;
  assert.equal((await capture(healthy, () => true, progress, 5)).cancelled, true);
  assert.equal(calls, 0);
  completed = [];
  assert.equal((await capture(healthy, () => calls > 0, progress, 5)).cancelled, true);
  assert.equal(completed.length, 0);
  const absent = async () => { const s = await healthy(); s.face.confidence = 0; s.skeleton = {}; return s; };
  assert.equal((await capture(absent, () => false, progress, 5)).isUsable, false);
  await assert.rejects(capture(async () => { throw new Error('camera failed'); }, () => false, progress, 5),
    /camera failed/);
  const { floatingScore, floatingStatus } = after('models/FloatingStatus');
  const reading = { score: 92, summary: '坐姿在线', timestamp: now, guarding: true, foreground: true, simulated: false };
  assert.equal(floatingScore(reading, now), '92');
  assert.equal(floatingStatus(reading, now), '坐姿在线');
  for (const invalid of [{ foreground: false }, { guarding: false }, { timestamp: 0 },
    { timestamp: now - 15001 }, { timestamp: now + 1 }]) {
    assert.equal(floatingScore({ ...reading, ...invalid }, now), '--');
  }
  assert.ok(floatingStatus({ ...reading, simulated: true }, now).includes('模拟'));
  console.log('PASS: five-frame calibration, cancel-before/during-frame, no-person rejection, capture errors and stale float state');
  await verifyGuardLifecycle();
}

function guardHarness(mode = 'healthy') {
  const calls = [];
  const methods = ['startGuard', 'stopGuard', 'runCalibration', 'calibrateFromCurrent', 'releasePostureSource',
    'onForegroundChanged', 'copySettings', 'controlsLocked'];
  const compiled = ts.transpileModule(`class GuardHarness { ${methods.map(name => pageMethod(false, name)).join('\n')} }
    new GuardHarness();`, { compilerOptions: { target: ts.ScriptTarget.ES2020 } }).outputText;
  const page = vm.runInNewContext(compiled, {
    Date: TestDate, ReminderAction: types.ReminderAction,
    captureCalibration: after('models/CalibrationCapture').captureCalibration,
    buildCalibrationProfile: after('models/PostureCalibration').buildCalibrationProfile,
    QUICK_CALIBRATION_FRAME_COUNT: 5, CALIBRATION_FRAME_COUNT: 10,
    CALIBRATION_COUNTDOWN_SECONDS: 3, CALIBRATION_COUNTDOWN_DELAY_MS: 1000,
    setInterval: () => { calls.push('timer'); return 1; }, clearInterval: () => calls.push('clear-timer')
  });
  Object.assign(page, {
    isGuarding: false, isSampling: false, isStartingGuard: false, isStoppingGuard: false,
    isManualOperation: false, pageRunId: 1, guardRunId: 0, timer: -1, appForeground: true,
    settings: normalize(types.createDefaultSettings()), saveCount: 0, captured: 0,
    clearSessionReport: () => calls.push('clear-report'), abilityContext: () => ({}),
    isCurrentPageRun: id => id === page.pageRunId,
    prepareSourceAccess: async () => true,
    rebuildPostureSource: async () => calls.push('prepare-source'),
    syncSourceStatus: () => calls.push('sync-source'), createPostureSource: () => page.postureSource,
    setCalibrationProgress: (text, healthy, percent) => { page.progress = { text, healthy, percent }; },
    sleep: async () => { if (mode === 'countdown-cancel') page.calibrationCancelled = true; },
    formatClock: () => '12:00:00', resetDisplayStability: () => {}, resetReminderState: () => {},
    cancelHardReminderTimer: () => {}, stopReminderFeedback: () => {},
    persistData: () => { page.saveCount++; }, captureFrame: () => calls.push('capture-live'),
    buildSessionReport: () => calls.push('report'),
    reminder: { reset: () => calls.push('reset-reminder') },
    guardWindow: { enter: async () => calls.push('enter-window'), leave: async () => calls.push('leave-window'),
      statusDetail: () => '' },
    postureSource: {
      sample: async () => {
        page.captured++;
        if (mode === 'throw') throw new Error('camera failed');
        if (mode === 'cancel') page.calibrationCancelled = true;
        if (mode === 'background') { page.appForeground = false; page.onForegroundChanged(); }
        if (mode === 'disappear') page.pageRunId++;
        const frame = generate(0, page.settings.profile);
        if (mode === 'absent') { frame.face.confidence = 0; frame.skeleton = {}; }
        return frame;
      },
      dispose: async () => calls.push('dispose')
    }
  });
  return { page, calls };
}

async function verifyGuardLifecycle() {
  for (const mode of ['healthy', 'cancel', 'countdown-cancel', 'absent', 'throw', 'background', 'disappear']) {
    const { page, calls } = guardHarness(mode);
    const oldProfile = normalize(page.settings.profile);
    await page.startGuard();
    if (mode === 'healthy') {
      assert.equal(page.captured, 5);
      assert.equal(page.saveCount, 1);
      assert.equal(page.isGuarding, true);
      assert.equal(page.lastSample, undefined, 'Calibration must not appear as a live reading');
      assert.equal(page.progress.percent, 100);
      assert.ok(calls.indexOf('enter-window') < calls.indexOf('capture-live'));
      await page.stopGuard(true, true);
      assert.equal(page.isGuarding, false);
      assert.ok(calls.includes('report'));
      assert.ok(calls.includes('dispose'));
      assert.ok(calls.includes('leave-window'));
      await page.startGuard();
      assert.equal(page.captured, 10, 'Each new session must calibrate again');
      await page.stopGuard();
    } else {
      assert.equal(page.saveCount, 0, `${mode} must not persist baseline`);
      assert.deepEqual(normalize(page.settings.profile), oldProfile);
      assert.equal(page.isGuarding, false);
      assert.equal(page.isStartingGuard, false);
      assert.equal(page.isSampling, false);
      assert.equal(calls.filter(v => v === 'dispose').length, 1);
      assert.ok(!calls.includes('capture-live'));
      assert.ok(!calls.includes('timer'));
    }
  }
  const { page } = guardHarness();
  await page.calibrateFromCurrent();
  assert.equal(page.captured, 10);
  assert.equal(page.saveCount, 1);
  assert.equal(page.isManualOperation, false);
  assert.equal(page.isGuarding, false);
  const disposing = guardHarness();
  let release;
  let released = 0;
  disposing.page.postureSource.dispose = () => { released++; return new Promise(resolve => { release = resolve; }); };
  const first = disposing.page.releasePostureSource();
  const second = disposing.page.releasePostureSource();
  assert.equal(released, 1);
  release();
  await first;
  await second;
  console.log('PASS: actual start/stop/manual-calibration methods, repeat starts, no baseline writes on cancellation/failure, serialized disposal');
}
verifyNewFlows().catch((error) => { console.error(error); process.exitCode = 1; });
