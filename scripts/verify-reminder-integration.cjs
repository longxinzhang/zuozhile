#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const ts = require('./deveco-sdk.cjs').typescript;
const root = path.resolve(__dirname, '..');
const sourceRoot = 'entry/src/main/ets/';
const baseline = process.argv[2] || 'd73d591';
const compilerOptions = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS };
function read(file, previous = false) {
  return previous ? execFileSync('git', ['show', `${baseline}:${file}`], { cwd: root, encoding: 'utf8' })
    : fs.readFileSync(path.join(root, file), 'utf8');
}
function tree(file, previous = false) {
  return ts.createSourceFile(file, read(file, previous).replaceAll('struct ', 'class '), ts.ScriptTarget.Latest, true);
}
function pageMethod(name, previous = false) {
  const ast = tree(sourceRoot + 'pages/Index.ets', previous);
  const page = ast.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'Index');
  const member = page.members.find(node => node.name?.getText(ast) === name);
  assert.ok(member, 'Missing Index method: ' + name);
  return member.getText(ast);
}
function load(file, mocks = {}, previous = false, cache = new Map()) {
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} }; cache.set(file, module);
  vm.runInNewContext(ts.transpileModule(read(sourceRoot + file + '.ets', previous), { compilerOptions }).outputText,
    { module, exports: module.exports, Date, console, require(name) {
      if (Object.hasOwn(mocks, name)) return mocks[name];
      assert.ok(name.startsWith('.'), 'Unexpected native dependency: ' + name);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)), mocks, previous, cache);
    } });
  return module.exports;
}
const types = load('models/PostureTypes');
const rules = load('models/LowScoreReminder');
const normalize = value => JSON.parse(JSON.stringify(value));
for (const name of ['models/PostureEvaluator.ets', 'models/PostureCalibration.ets', 'models/CalibrationCapture.ets',
  'models/SessionStats.ets', 'models/ReminderEngine.ets', 'services/CoreVisionPostureSource.ets',
  'services/MockFrameSampler.ets', 'services/MockPostureSource.ets', 'services/GuardWindowService.ets']) {
  assert.equal(read(sourceRoot + name), read(sourceRoot + name, true), name + ' changed');
}
for (const file of execFileSync('git', ['ls-files', 'entry/src/main/cpp'], { cwd: root, encoding: 'utf8' }).trim().split('\n')) {
  if (file) assert.equal(read(file), read(file, true), file + ' changed');
}
for (const name of ['setIntervalMs', 'appendRecord', 'shouldAdoptMetric', 'buildSessionReport', 'sampleSkeletonOnce']) {
  assert.equal(pageMethod(name), pageMethod(name, true), name + ' changed');
}
const stripHooks = text => text.replace(/^\s*this\.(stopReminderPreview|stopLowScoreReminders)\(\);\n/gm, '')
  .replace(/^\s*this\.reminder\.reset\(\);\n/gm, '');
for (const name of ['runCalibration', 'setSensitivity', 'resetCalibration']) {
  assert.equal(stripHooks(pageMethod(name)), stripHooks(pageMethod(name, true)), name + ' changed beyond reminder hooks');
}
const detectorAst = tree(sourceRoot + 'services/CoreVisionPostureDetector.ets');
const oldDetectorAst = tree(sourceRoot + 'services/CoreVisionPostureDetector.ets', true);
const getMembers = ast => ast.statements.find(node => ts.isClassDeclaration(node) &&
  node.name.text === 'CoreVisionPostureDetector').members;
for (const old of getMembers(oldDetectorAst)) {
  if (!old.name || old.name.getText(oldDetectorAst) === 'detect') continue;
  const current = getMembers(detectorAst).find(node => node.name?.getText(detectorAst) === old.name.getText(oldDetectorAst));
  assert.equal(current.getText(detectorAst), old.getText(oldDetectorAst), 'Detector selection/conversion changed');
}
console.log('PASS: scoring, calibration, sensitivity, interval, camera pipeline, native inference and statistics untouched');

const newEvaluate = load('models/PostureEvaluator').evaluatePosture;
const oldEvaluate = load('models/PostureEvaluator', {}, true).evaluatePosture;
const generate = load('services/MockFrameSampler').createSimulatedSample;
let comparisons = 0;
for (const sensitivity of [types.STANDARD_SENSITIVITY, types.SENSITIVE_SENSITIVITY]) {
  for (const interval of [2000, 3000, 5000]) {
    const profile = { ...types.createDefaultCalibration(), sensitivity, sampleIntervalMs: interval };
    for (let i = 0; i < 420; i++) {
      const sample = generate(i, profile);
      const patches = [sample, { ...sample, face: { ...sample.face, confidence: 0 } },
        { ...sample, skeleton: {} }, { ...sample, face: { ...sample.face, mouthAvailable: false } }];
      for (const frame of patches) {
        assert.deepEqual(normalize(newEvaluate(frame, profile)), normalize(oldEvaluate(frame, profile)));
        comparisons++;
      }
    }
  }
}
console.log(`PASS: ${comparisons} scoring comparisons match ${baseline}`);

const pageNames = ['captureFrame', 'applyLowScoreDecision', 'lowScoreContext', 'lowScoreLevelText',
  'scheduleReminderExpiry', 'cancelReminderExpiry', 'cancelBreakMessage', 'dispatchLowScoreFeedback',
  'markReminderFeedbackRecord', 'stopReminderFeedback', 'stopLowScoreReminders', 'resetReminderState',
  'clearReminderDisplay', 'stopReminderPreview', 'startReminderPreview', 'previewReminderVibration',
  'isCurrentPageRun', 'controlsLocked', 'toggleLowScoreEdgeLight', 'toggleReduceReminderMotion', 'toggleVibration',
  'onForegroundChanged', 'aboutToDisappear', 'startGuard', 'stopGuard', 'runCalibration',
  'releasePostureSource', 'copySettings', 'setCalibrationProgress'];
let now = Date.UTC(2026, 9, 14, 9);
class ClockDate extends Date { static now() { return now; } }
function createPage() {
  const calls = { records: 0, saved: 0, applied: 0, pairs: 0, stopped: 0, sourceSamples: 0 };
  const timers = new Map(); let nextTimer = 0;
  const cooldown = new rules.ReminderVibrationCooldown();
  const feedback = { isAvailable: () => true, statusDetail: () => '本地马达可用', async stop() { calls.stopped++; },
    async pulsePair(current, started) { if (!current()) return false; calls.pairs++; started(); return true; } };
  const p = vm.runInNewContext(ts.transpileModule(`class Subject { ${pageNames.map(name => pageMethod(name)).join('\n')} }
    new Subject();`, { compilerOptions }).outputText, {
    Date: ClockDate, ...types, ...rules, PHONE_VIBRATION_COOLDOWN: cooldown,
    ReminderFeedbackService: feedback, BREAK_MESSAGE_TIMEOUT_MS: 8000,
    captureCalibration: load('models/CalibrationCapture').captureCalibration,
    buildCalibrationProfile: load('models/PostureCalibration').buildCalibrationProfile,
    QUICK_CALIBRATION_FRAME_COUNT: 5, CALIBRATION_FRAME_COUNT: 10,
    CALIBRATION_COUNTDOWN_SECONDS: 3, CALIBRATION_COUNTDOWN_DELAY_MS: 1000,
    evaluatePosture: sample => sample.result,
    setTimeout: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, due: now + delay }); return id; },
    clearTimeout: id => timers.delete(id),
    setInterval: (callback, delay) => { const id = ++nextTimer; timers.set(id, { callback, due: now + delay }); return id; },
    clearInterval: id => timers.delete(id)
  });
  const profile = types.createDefaultCalibration();
  Object.assign(p, { pageRunId: 1, guardRunId: 1, guardSessionStartedAt: now, appForeground: true,
    isGuarding: true, isSampling: false, isCalibrating: false, isManualOperation: false,
    isStartingGuard: false, isStoppingGuard: false, lowScoreLevel: 0, lowScoreEdgeVisible: false,
    lowScoreDataValid: false, lowScoreExpiresAt: 0, lowScoreLatestScore: 100,
    reminderPreviewLevel: 0, reminderPreviewRunId: 0, reminderPreviewMessage: '', activeTab: 3, showDebugPanel: true,
    reminderAction: types.ReminderAction.NONE, reminderAlertType: types.PostureAlertType.NONE, reminderMessage: '',
    reminderExpiryTimer: -1, breakMessageTimer: -1, reminderExpiryRunId: 0, breakMessageRunId: 0,
    summary: '', records: [],
    settings: types.createDefaultSettings(), lowScoreScheduler: new rules.LowScoreReminderScheduler(cooldown),
    applyResult() { calls.applied++; }, syncSourceStatus() {}, copySettings: value => normalize(value),
    persistData() { calls.saved++; }, stopGuard: async () => { p.isGuarding = false; },
    appendRecord(result) { calls.records++; p.records.unshift({ timestamp: result.timestamp, score: result.score,
      sitLevel: result.sit.level, chinLevel: result.chin.level, mouthLevel: result.mouth.level,
      action: result.action, alertType: result.primaryAlert }); },
    postureSource: { status: () => ({ isLive: true }), async sample() {
      calls.sourceSamples++; return p.frame;
    } }
  });
  p.settings.profile = profile; p.lowScoreScheduler.beginSession(1, now);
  function setFrame(score) {
    const metric = { level: types.PostureLevel.BAD, score, value: 35, baseline: 0,
      label: '低头', alertType: types.PostureAlertType.ITEM_03 };
    p.frame = { timestamp: now, face: { confidence: .99, pitch: -35, roll: 0, yaw: 0,
      mouthAvailable: false, mouthOpenRatio: 0, rect: { left: 100, top: 80, width: 100, height: 120 } },
      skeleton: { nose: { x: 200, y: 120, score: .9 }, leftShoulder: { x: 100, y: 300, score: .9 },
        rightShoulder: { x: 300, y: 300, score: .9 } },
      reminderEvidence: { faceCount: 1, skeletonCount: 1, associationAmbiguous: false },
      result: { timestamp: now, score, sit: metric, chin: metric,
        mouth: { ...metric, level: types.PostureLevel.UNKNOWN, alertType: types.PostureAlertType.NONE },
        summary: '', primaryAlert: types.PostureAlertType.ITEM_03, activeAlerts: [types.PostureAlertType.ITEM_03],
        action: types.ReminderAction.NONE } };
  }
  async function capture(score, elapsed = 0, force = false) {
    now += elapsed; setFrame(score); await p.captureFrame(force); await Promise.resolve();
  }
  return { p, calls, timers, capture, setFrame, feedback };
}

function guardHarness(mode) {
  const f = createPage(), p = f.p, calls = [];
  delete p.stopGuard; delete p.copySettings;
  p.lowScoreScheduler.stop();
  Object.assign(p, { isGuarding: false, guardRunId: 0, guardSessionStartedAt: 0, timer: -1,
    clearSessionReport: () => calls.push('clear-report'), abilityContext: () => ({}),
    prepareSourceAccess: async () => true, rebuildPostureSource: async () => calls.push('source-ready'),
    resetDisplayStability: () => {}, formatClock: () => '09:00:00',
    sleep: async () => { if (mode === 'countdown-cancel') p.calibrationCancelled = true; },
    captureFrame: () => calls.push('live-sample'),
    buildSessionReport: () => calls.push('report'),
    guardWindow: { enter: async () => calls.push('enter-window'), leave: async () => calls.push('leave-window'),
      statusDetail: () => '' },
    postureSource: { status: () => ({ isLive: true }), sample: async () => {
      f.calls.sourceSamples++;
      if (mode === 'throw') throw Error('camera failed');
      if (mode === 'cancel') p.calibrationCancelled = true;
      if (mode === 'background') { p.appForeground = false; p.onForegroundChanged(); }
      if (mode === 'disappear') p.pageRunId++;
      const sample = generate(0, p.settings.profile);
      if (mode === 'missing') { sample.face.confidence = 0; sample.skeleton = {}; }
      return sample;
    }, dispose: async () => calls.push('dispose') }
  });
  return { ...f, flowCalls: calls };
}

async function main() {
  const f = createPage();
  await f.capture(49); await f.capture(49, 3000); await f.capture(49, 3000);
  assert.equal(f.p.lowScoreLevel, 3); assert.equal(f.calls.pairs, 1);
  assert.equal(f.p.records.filter(r => r.action !== types.ReminderAction.NONE).length, 1);
  for (let i = 0; i < 19; i++) await f.capture(49, 3000);
  assert.equal(f.calls.pairs, 1);
  await f.capture(49, 3000);
  assert.equal(f.calls.pairs, 2);
  assert.equal(f.p.records.filter(r => r.action !== types.ReminderAction.NONE).length, 2);
  assert.equal(f.calls.sourceSamples, 23);
  console.log('PASS: actual capture integrates one dispatcher; combined light/vibration counts once; repeated haptic counts only on success');

  const visualOnly = createPage();
  await visualOnly.capture(59); await visualOnly.capture(59, 3000); await visualOnly.capture(59, 3000);
  visualOnly.p.settings.vibration = false;
  await visualOnly.capture(49, 3000); await visualOnly.capture(49, 3000); await visualOnly.capture(49, 3000);
  assert.equal(visualOnly.p.lowScoreLevel, 3); assert.equal(visualOnly.calls.pairs, 0);
  assert.equal(visualOnly.p.records.filter(r => r.action !== types.ReminderAction.NONE).length, 1);
  const failed = createPage();
  failed.feedback.pulsePair = async () => false;
  await failed.capture(49); await failed.capture(49, 3000); await failed.capture(49, 3000);
  for (let i = 0; i < 20; i++) await failed.capture(49, 3000);
  assert.equal(failed.p.records.filter(r => r.action !== types.ReminderAction.NONE).length, 1);
  assert.equal(failed.p.lowScoreLevel, 3);
  console.log('PASS: disabled/failed vibration retains visual state without phantom repeated reminder records');

  const invalid = createPage();
  await invalid.capture(49); await invalid.capture(49, 3000); await invalid.capture(49, 3000);
  now += 3000; invalid.setFrame(49); delete invalid.p.frame.skeleton.leftShoulder;
  await invalid.p.captureFrame();
  assert.equal(invalid.p.lowScoreLevel, 0); assert.equal(invalid.p.lowScoreDataValid, false);
  assert.equal(invalid.p.reminderExpiryTimer, -1); assert.equal(invalid.calls.pairs, 1);
  invalid.p.postureSource.sample = async () => { throw Error('stream failure'); };
  await invalid.p.captureFrame(); assert.equal(invalid.p.lowScoreLevel, 0);
  assert.equal(invalid.p.summary, '采样失败');
  console.log('PASS: invalid keypoints and source errors immediately cancel visuals, pending feedback and expiry tasks');

  for (const patch of [{ settings: { ...types.createDefaultSettings(), useCoreVision: false } },
    { isGuarding: false }, { isCalibrating: true }, { appForeground: false }]) {
    const test = createPage(); Object.assign(test.p, patch);
    await test.capture(49, 0, true); await test.capture(49, 3000, true); await test.capture(49, 3000, true);
    assert.equal(test.calls.records, 0); assert.equal(test.calls.pairs, 0); assert.equal(test.p.lowScoreLevel, 0);
  }
  const stale = createPage(); let finish;
  stale.setFrame(49); const old = stale.p.frame;
  stale.p.postureSource.sample = () => new Promise(resolve => { finish = resolve; });
  const pending = stale.p.captureFrame(true); stale.p.guardRunId++;
  finish(old); await pending;
  assert.equal(stale.calls.applied, 0); assert.equal(stale.calls.records, 0);
  console.log('PASS: mock/diagnostic/calibration/background samples do not issue or record reminders; forced stale callbacks ignored');

  const expiring = createPage();
  await expiring.capture(59); await expiring.capture(59, 3000); await expiring.capture(59, 3000);
  const timer = expiring.timers.get(expiring.p.reminderExpiryTimer);
  now = timer.due; timer.callback();
  assert.equal(expiring.p.lowScoreLevel, 0); assert.equal(expiring.p.lowScoreDataValid, false);
  assert.equal(expiring.p.reminderExpiryTimer, -1);
  const noUpgrade = createPage(); await noUpgrade.capture(49);
  const only = noUpgrade.timers.get(noUpgrade.p.reminderExpiryTimer);
  now = only.due; only.callback(); assert.equal(noUpgrade.p.lowScoreLevel, 0); assert.equal(noUpgrade.calls.pairs, 0);
  const replaced = createPage(); await replaced.capture(59);
  const oldExpiry = replaced.timers.get(replaced.p.reminderExpiryTimer);
  await replaced.capture(59, 3000);
  const currentTimer = replaced.p.reminderExpiryTimer;
  oldExpiry.callback(); assert.equal(replaced.p.reminderExpiryTimer, currentTimer);
  assert.equal(replaced.timers.size, 1, 'Old expiry cannot replace or orphan the current task');
  replaced.p.stopLowScoreReminders(); oldExpiry.callback();
  assert.equal(replaced.timers.size, 0); assert.equal(replaced.p.lowScoreDataValid, false);
  console.log('PASS: actual UI expiry callback only clears state, never promotes an old sample or vibrates');

  const breaking = createPage();
  const breakDecision = new rules.LowScoreDecision();
  breakDecision.breakEvent = true; breakDecision.message = '休息一下';
  breakDecision.expiresAt = now + 7000;
  breaking.p.applyLowScoreDecision(breakDecision);
  const oldBreak = breaking.timers.get(breaking.p.breakMessageTimer);
  const currentBreak = new rules.LowScoreDecision();
  currentBreak.level = 2; currentBreak.edgeVisible = true; currentBreak.message = '请抬头';
  currentBreak.expiresAt = now + 7000;
  breaking.p.applyLowScoreDecision(currentBreak); oldBreak.callback();
  assert.equal(breaking.p.reminderMessage, '请抬头');
  assert.equal(breaking.p.reminderAlertType, types.PostureAlertType.NONE);
  console.log('PASS: low-score text preempts rest text; cancelled rest callbacks cannot erase the current reminder');

  const preview = createPage(); preview.p.isGuarding = false;
  const snapshot = normalize({ score: preview.p.score, settings: preview.p.settings, records: preview.p.records });
  preview.p.startReminderPreview(3); await preview.p.previewReminderVibration();
  assert.equal(preview.calls.sourceSamples, 0); assert.equal(preview.calls.records, 0); assert.equal(preview.calls.saved, 0);
  assert.equal(preview.calls.pairs, 1);
  await preview.p.previewReminderVibration(); assert.equal(preview.calls.pairs, 1);
  assert.match(preview.p.reminderPreviewMessage, /冷却/);
  assert.deepEqual(normalize({ score: preview.p.score, settings: preview.p.settings, records: preview.p.records }), snapshot);
  preview.p.appForeground = false; preview.p.onForegroundChanged();
  assert.equal(preview.p.reminderPreviewLevel, 0);
  assert.equal(preview.p.lowScoreDataValid, false);
  preview.p.aboutToDisappear(); assert.equal(preview.timers.size, 0);
  console.log('PASS: isolated preview cannot modify camera, score, baseline/statistics; shares phone cooldown and cleans up on background/disposal');

  let raw = JSON.stringify({ settings: { ...types.createDefaultSettings(), lowScoreEdgeLight: false,
    reduceReminderMotion: true }, records: [], lastUpdatedAt: now });
  const store = load('services/PostureSessionStore', { '@kit.ArkData': { preferences: { getPreferences: async () => ({
    get: async () => raw, put: async (key, value) => { raw = value; }, flush: async () => {}
  }) } } });
  let loaded = await store.PostureSessionStore.loadWithStatus({});
  assert.equal(loaded.data.settings.lowScoreEdgeLight, false); assert.equal(loaded.data.settings.reduceReminderMotion, true);
  const legacy = JSON.parse(raw); delete legacy.settings.lowScoreEdgeLight; delete legacy.settings.reduceReminderMotion;
  raw = JSON.stringify(legacy); loaded = await store.PostureSessionStore.loadWithStatus({});
  assert.equal(loaded.data.settings.lowScoreEdgeLight, true); assert.equal(loaded.data.settings.reduceReminderMotion, false);
  await store.PostureSessionStore.save({}, loaded.data);
  assert.equal(JSON.parse(raw).settings.lowScoreEdgeLight, true);
  console.log('PASS: reminder switches persist; legacy settings migrate without changing calibration or interval');

  assert.doesNotMatch(read(sourceRoot + 'pages/Index.ets'), /reminder\.feed|ReminderFeedbackService\.notify|showHardReminder|HardReminderOverlay/);
  assert.doesNotMatch(read(sourceRoot + 'services/ReminderFeedbackService.ets'), /AudioKit|playSystemSound|notify\(/);
  assert.doesNotMatch(pageMethod('startReminderPreview') + pageMethod('previewReminderVibration'),
    /captureFrame|runCalibration|appendRecord|persistData|evaluatePosture/);
  const pageSource = read(sourceRoot + 'pages/Index.ets');
  assert.equal((pageSource.match(/LowScoreEdgeLight\(\{/g) || []).length, 1,
    'Real reminders and isolated preview must share one screen-sized glow, never a card-local effect');
  assert.match(pageMethod('build'), /level: this\.reminderPreviewLevel > LowScoreLevel\.NORMAL \?/);
  assert.match(pageMethod('build'), /expandSafeArea\(\[SafeAreaType\.SYSTEM, SafeAreaType\.CUTOUT\]/);
  assert.doesNotMatch(pageMethod('ReminderPreviewPanel'), /LowScoreEdgeLight|height\(200\)|clip\(true\)/);
  console.log('PASS: no legacy independent vibration/sound/strong-popup path or preview side effects remain');

  for (const mode of ['healthy', 'cancel', 'countdown-cancel', 'missing', 'throw', 'background', 'disappear']) {
    const f = guardHarness(mode), p = f.p;
    const profile = normalize(p.settings.profile);
    p.reminderPreviewLevel = 3;
    await p.startGuard();
    assert.equal(p.reminderPreviewLevel, 0);
    if (mode === 'healthy') {
      assert.equal(f.calls.sourceSamples, 5); assert.equal(f.calls.saved, 1);
      assert.equal(p.isGuarding, true); assert.equal(p.lastSample, undefined);
      assert.equal(f.calls.records, 0); assert.equal(f.calls.pairs, 0);
      assert.ok(f.flowCalls.indexOf('enter-window') < f.flowCalls.indexOf('live-sample'));
      assert.equal(f.timers.size, 1);
      await p.stopGuard(true, true);
      assert.equal(p.isGuarding, false); assert.equal(f.timers.size, 0);
      assert.ok(f.flowCalls.includes('report')); assert.ok(f.flowCalls.includes('dispose'));
      await p.startGuard(); assert.equal(f.calls.sourceSamples, 10); await p.stopGuard();
    } else {
      assert.equal(p.isGuarding, false); assert.equal(p.isStartingGuard, false);
      assert.equal(p.lowScoreLevel, 0); assert.equal(p.lowScoreDataValid, false);
      assert.equal(f.calls.saved, 0); assert.equal(f.calls.records, 0); assert.equal(f.calls.pairs, 0);
      assert.equal(f.timers.size, 0); assert.deepEqual(normalize(p.settings.profile), profile);
    }
  }
  console.log('PASS: actual guard start/stop/calibration preserve frame counts/baselines, close preview, clear tasks and reject cancelled/background sessions');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
