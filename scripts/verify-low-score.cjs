#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');

const root = path.resolve(__dirname, '..');
const ts = require('./deveco-sdk.cjs').typescript;
const sourceRoot = path.join(root, 'entry/src/main/ets');
const compilerOptions = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS };
function load(name, mocks = {}, globals = {}, cache = new Map()) {
  if (cache.has(name)) return cache.get(name).exports;
  const module = { exports: {} };
  cache.set(name, module);
  const file = path.join(sourceRoot, name + '.ets');
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), { compilerOptions }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, Date, console, ...globals, require(dependency) {
    if (Object.hasOwn(mocks, dependency)) return mocks[dependency];
    assert.ok(dependency.startsWith('.'), `Unexpected dependency: ${dependency}`);
    return load(path.posix.normalize(path.posix.join(path.posix.dirname(name), dependency)), mocks, globals, cache);
  } }, { filename: file });
  return module.exports;
}

const types = load('models/PostureTypes');
const rules = load('models/LowScoreReminder');
const { LowScoreLevel: Level, LowScoreReminderScheduler: Scheduler, LowScoreReminderContext: Context,
  ReminderVibrationCooldown: Cooldown } = rules;
const base = Date.UTC(2026, 9, 14, 8);
let checks = 0;
function check(name, run) {
  run(); checks++;
  console.log('PASS: ' + name);
}
function fixture(intervalMs = 3000, cooldown = new Cooldown(), sessionId = 1, startedAt = base) {
  const context = Object.assign(new Context(), { sessionId, startedAt, intervalMs, foreground: true,
    guarding: true, realSource: true });
  const scheduler = new Scheduler(cooldown);
  scheduler.beginSession(sessionId, startedAt);
  return { context, scheduler, cooldown };
}
function reading(score, at, patch = {}) {
  const metric = { level: types.PostureLevel.BAD, value: 35, baseline: 0, score,
    label: '低头', alertType: types.PostureAlertType.ITEM_03 };
  const sample = { timestamp: at, skeleton: { nose: { x: 200, y: 120, score: .9 },
    leftShoulder: { x: 100, y: 300, score: .9 }, rightShoulder: { x: 300, y: 300, score: .9 } },
    face: { confidence: .98, yaw: 0, pitch: -35, roll: 0, mouthOpenRatio: 0,
      mouthAvailable: false, rect: { left: 150, top: 80, width: 100, height: 140 } },
    reminderEvidence: { faceCount: 1, skeletonCount: 1, associationAmbiguous: false } };
  const result = { timestamp: at, sit: metric, chin: metric,
    mouth: { ...metric, level: types.PostureLevel.UNKNOWN, alertType: types.PostureAlertType.NONE },
    score, summary: '', action: types.ReminderAction.NONE,
    activeAlerts: [types.PostureAlertType.ITEM_03], primaryAlert: types.PostureAlertType.ITEM_03 };
  if (patch.sample) Object.assign(sample, patch.sample);
  if (patch.result) Object.assign(result, patch.result);
  return { sample, result };
}
function feed(f, score, offset, patch = {}, nowOffset = offset) {
  const { sample, result } = reading(score, base + offset, patch);
  return f.scheduler.feed(sample, result, f.context, base + nowOffset);
}
function confirm(f, score, start = 0) {
  let decision;
  for (let t = start; t <= start + 10000; t += f.context.intervalMs) {
    decision = feed(f, score, t);
    if (decision.level !== Level.NORMAL) break;
  }
  return decision;
}

check('49/50/59/60/69/70 boundaries at unchanged 2/3/5 second intervals', () => {
  for (const interval of [2000, 3000, 5000]) {
    for (const [score, expected] of [[49, 3], [50, 2], [59, 2], [60, 1], [69, 1], [70, 0]]) {
      const f = fixture(interval);
      let events = 0, vibrations = 0;
      for (let t = 0; t <= 10000; t += interval) {
        const d = feed(f, score, t);
        assert.equal(d.level, t < 6000 ? 0 : expected);
        assert.equal(d.validSample, true);
        events += Number(d.visualEvent); vibrations += Number(d.vibrate);
      }
      assert.equal(events, expected > 0 ? 1 : 0);
      assert.equal(vibrations, expected === 3 ? 1 : 0);
    }
  }
});

check('two valid fresh samples and sample timestamps, never timer-driven promotion', () => {
  const f = fixture();
  assert.equal(feed(f, 49, 0).level, 0);
  for (const t of [3000, 6000, 7000]) {
    const d = f.scheduler.refresh(f.context, base + t);
    assert.equal(d.level, 0); assert.equal(d.vibrate, false);
  }
  assert.equal(feed(f, 49, 0, {}, 6000).level, 0);
  assert.equal(feed(f, 49, 6000).level, 3);
  const single = fixture(5000);
  assert.equal(feed(single, 49, 0).level, 0);
  assert.equal(single.scheduler.refresh(single.context, base + 6000).level, 0);
  assert.equal(feed(single, 49, 11001).level, 0, 'Gap must restart confirmation');
});

check('transient low scores reset each independent threshold and severe entry never borrows light time', () => {
  const f = fixture();
  assert.equal(feed(f, 69, 0).level, 0);
  assert.equal(feed(f, 70, 3000).level, 0);
  assert.equal(feed(f, 69, 6000).level, 0);
  assert.equal(feed(f, 69, 9000).level, 0);
  assert.equal(feed(f, 69, 12000).level, 1);
  assert.equal(feed(f, 49, 15000).level, 1);
  assert.equal(feed(f, 49, 18000).level, 1);
  assert.equal(feed(f, 49, 21000).level, 3);
  const reset = fixture();
  feed(reset, 49, 0); feed(reset, 59, 3000);
  assert.equal(feed(reset, 49, 6000).level, 2);
  assert.equal(feed(reset, 49, 9000).level, 2);
  assert.equal(feed(reset, 49, 12000).level, 3);
});

check('69/71, 59/61, 49/51 oscillation retains the existing level without repeated events', () => {
  for (const [low, high, level] of [[69, 71, 1], [59, 61, 2], [49, 51, 3]]) {
    const f = fixture();
    assert.equal(confirm(f, low).level, level);
    for (let t = 9000; t <= 57000; t += 3000) {
      const d = feed(f, t / 3000 % 2 ? high : low, t);
      assert.equal(d.level, level); assert.equal(d.visualEvent, false); assert.equal(d.vibrate, false);
    }
  }
});

check('53/63/73 recovery requires consecutive samples, supports multi-level descent and 70-72 retention', () => {
  const f = fixture(); confirm(f, 49);
  assert.equal(feed(f, 53, 9000).level, 3);
  assert.equal(feed(f, 52, 12000).level, 3);
  assert.equal(feed(f, 53, 15000).level, 3);
  assert.equal(feed(f, 53, 18000).level, 2);
  assert.equal(feed(f, 63, 21000).level, 2);
  assert.equal(feed(f, 63, 24000).level, 1);
  assert.equal(feed(f, 72, 27000).level, 1);
  assert.equal(feed(f, 73, 30000).level, 1);
  assert.equal(feed(f, 72, 33000).level, 1);
  assert.equal(feed(f, 73, 36000).level, 1);
  const end = feed(f, 73, 39000);
  assert.equal(end.level, 0); assert.equal(end.edgeVisible, false); assert.equal(end.visualEvent, false);
  const jump = fixture(); confirm(jump, 49);
  feed(jump, 73, 9000); assert.equal(feed(jump, 73, 12000).level, 0);
});

check('60 second cooldown survives recovery, pause/restart, page recreation and settings changes', () => {
  const cooldown = new Cooldown();
  const f = fixture(3000, cooldown); assert.equal(confirm(f, 49).vibrate, true);
  feed(f, 73, 9000); feed(f, 73, 12000);
  feed(f, 49, 15000); feed(f, 49, 18000);
  assert.equal(feed(f, 49, 21000).vibrate, false);
  f.scheduler.stop();
  const next = fixture(3000, cooldown, 2, base + 24000);
  assert.equal(confirm(next, 49, 24000).vibrate, false);
  next.context.vibrationEnabled = false;
  for (let t = 33000; t <= 66000; t += 3000) assert.equal(feed(next, 49, t).vibrate, false);
  next.context.vibrationEnabled = true;
  assert.equal(next.scheduler.refresh(next.context, base + 67000).vibrate, false);
  assert.equal(feed(next, 49, 69000).vibrate, true);
  assert.equal(feed(next, 49, 69000).vibrate, false);
  const recreated = fixture(3000, cooldown, 3, base + 72000);
  assert.equal(confirm(recreated, 49, 72000).vibrate, false);
});

check('repeat vibration needs a NEW score below 50, not expired cooldown with hysteresis-only severe state', () => {
  const f = fixture(); confirm(f, 49);
  for (let t = 9000; t <= 66000; t += 3000) {
    const d = feed(f, 51, t); assert.equal(d.level, 3); assert.equal(d.vibrate, false);
  }
  assert.equal(f.scheduler.refresh(f.context, base + 67000).vibrate, false);
  const repeat = feed(f, 49, 69000);
  assert.equal(repeat.vibrate, true); assert.equal(repeat.visualEvent, false);
});

check('medium-to-severe reuses the same visual, counts no new visual-only event when vibration is disabled', () => {
  const f = fixture();
  const medium = confirm(f, 59); assert.equal(medium.visualEvent, true);
  f.context.vibrationEnabled = false;
  feed(f, 49, 9000); feed(f, 49, 12000);
  const severe = feed(f, 49, 15000);
  assert.equal(severe.level, 3); assert.equal(severe.visualEvent, false); assert.equal(severe.vibrate, false);
  const light = fixture(); confirm(light, 69);
  feed(light, 49, 9000); feed(light, 49, 12000);
  const direct = feed(light, 49, 15000);
  assert.equal(direct.level, 3); assert.equal(direct.visualEvent, true); assert.equal(direct.vibrate, true);
});

check('invalid score, missing face/shoulders/nose, low confidence and multiplayer ambiguity stop reminders', () => {
  const valid = reading(49, base);
  const mutations = [
    ({ result }) => { result.score = NaN; }, ({ result }) => { result.score = Infinity; },
    ({ result }) => { result.score = -1; }, ({ result }) => { result.score = 101; },
    ({ sample }) => { sample.face.confidence = .24; },
    ({ sample }) => { sample.face.rect.width = 1; },
    ({ sample }) => { sample.face.pitch = NaN; },
    ({ sample }) => { delete sample.skeleton.leftShoulder; },
    ({ sample }) => { sample.skeleton.rightShoulder.score = .34; },
    ({ sample }) => { sample.skeleton.nose.x = Infinity; },
    ({ sample }) => { delete sample.reminderEvidence; },
    ({ sample }) => { sample.reminderEvidence.faceCount = 2; },
    ({ sample }) => { sample.reminderEvidence.skeletonCount = 2; },
    ({ sample }) => { sample.reminderEvidence.associationAmbiguous = true; },
    ({ result }) => { result.chin.level = types.PostureLevel.UNKNOWN; },
    ({ result }) => { result.timestamp++; }
  ];
  assert.equal(rules.reminderSampleIsReliable(valid.sample, valid.result), true, 'Mouth unavailable is allowed');
  for (const mutate of mutations) {
    const f = fixture(); confirm(f, 49);
    const invalid = reading(49, base + 9000); mutate(invalid);
    const d = f.scheduler.feed(invalid.sample, invalid.result, f.context, base + 9000);
    assert.equal(d.level, 0); assert.equal(d.vibrate, false); assert.equal(d.validSample, false);
    assert.equal(feed(f, 49, 12000).level, 0); assert.equal(feed(f, 49, 15000).level, 0);
    assert.equal(feed(f, 49, 18000).level, 3);
  }
  const duplicate = fixture(); confirm(duplicate, 49);
  const bad = reading(49, base + 6000); bad.sample.face.confidence = 0;
  assert.equal(duplicate.scheduler.feed(bad.sample, bad.result, duplicate.context, base + 6000).level, 0);
  assert.equal(feed(duplicate, 49, 6000).level, 0);
});

check('expiry at max(2*interval+1s,6s) clears all confirmation state without adding samples', () => {
  for (const [interval, limit] of [[2000, 6000], [3000, 7000], [5000, 11000]]) {
    const f = fixture(interval);
    const d = confirm(f, 49);
    const lastAt = d.expiresAt - limit;
    assert.equal(f.scheduler.refresh(f.context, lastAt + limit).level, 3);
    assert.equal(f.scheduler.refresh(f.context, lastAt + limit + 1).level, 0);
    assert.equal(feed(f, 49, lastAt - base + limit + 2).level, 0);
  }
});

check('calibration/background/stopped/simulated sessions and stale callbacks cannot relight', () => {
  for (const patch of [{ foreground: false }, { guarding: false }, { calibrating: true }, { realSource: false }]) {
    const f = fixture(); confirm(f, 49);
    Object.assign(f.context, patch);
    assert.equal(f.scheduler.refresh(f.context, base + 9000).level, 0);
    assert.equal(feed(f, 49, 9000).level, 0);
    Object.assign(f.context, { foreground: true, guarding: true, calibrating: false, realSource: true });
    assert.equal(feed(f, 49, 12000).level, 0);
  }
  const f = fixture(); confirm(f, 49);
  const oldContext = Object.assign(new Context(), f.context);
  f.scheduler.beginSession(2, base + 12000); f.context.sessionId = 2; f.context.startedAt = base + 12000;
  const old = reading(49, base + 6000);
  assert.equal(f.scheduler.feed(old.sample, old.result, oldContext, base + 12000).level, 0);
  assert.equal(f.scheduler.feed(old.sample, old.result, f.context, base + 12000).level, 0);
  assert.equal(feed(f, 49, 12000).level, 0); feed(f, 49, 15000);
  assert.equal(feed(f, 49, 18000).level, 3);
  f.scheduler.stop(); assert.equal(feed(f, 49, 21000).level, 0);
});

check('only current reliable primary problem yields advice; no cause inferred from total score', () => {
  const f = fixture(); confirm(f, 59);
  assert.equal(feed(f, 59, 9000).message, '请抬头');
  const neutral = { primaryAlert: types.PostureAlertType.NONE, activeAlerts: [] };
  assert.equal(feed(f, 59, 12000, { result: neutral }).message, '请调整坐姿');
  const lip = reading(59, base + 15000);
  lip.result.primaryAlert = types.PostureAlertType.ITEM_11;
  lip.result.activeAlerts = [types.PostureAlertType.ITEM_11];
  lip.result.mouth = { ...lip.result.mouth, level: types.PostureLevel.BAD, alertType: types.PostureAlertType.ITEM_11 };
  assert.equal(f.scheduler.feed(lip.sample, lip.result, f.context, base + 15000).message, '请轻合嘴唇');
  lip.sample.timestamp = lip.result.timestamp = base + 18000;
  lip.result.mouth.level = types.PostureLevel.UNKNOWN;
  assert.equal(f.scheduler.feed(lip.sample, lip.result, f.context, base + 18000).message, '请调整坐姿');
});

check('edge-light setting and reduced motion only affect presentation, never confirmation/cooldown', () => {
  const f = fixture(); f.context.edgeLightEnabled = false;
  const d = confirm(f, 69); assert.equal(d.level, 1); assert.equal(d.edgeVisible, false); assert.equal(d.visualEvent, false);
  f.context.edgeLightEnabled = true; f.context.reduceMotion = true;
  const live = f.scheduler.refresh(f.context, base + 7000);
  assert.equal(live.edgeVisible, true); assert.equal(live.reduceMotion, true); assert.equal(live.visualEvent, false);
  const severe = fixture(); severe.context.vibrationAvailable = false;
  assert.equal(confirm(severe, 49).vibrate, false);
});

check('20 minute break event is independent, deferred under ANY low-score level, and never stacks', () => {
  const f = fixture();
  let breaks = 0;
  for (let t = 0; t <= 20 * 60 * 1000 + 9000; t += 3000) {
    const d = feed(f, 69, t); assert.equal(d.breakEvent, false);
  }
  const at = 20 * 60 * 1000 + 12000;
  assert.equal(feed(f, 73, at).breakEvent, false);
  const d = feed(f, 73, at + 3000);
  breaks += Number(d.breakEvent); assert.equal(d.alertType, types.PostureAlertType.ITEM_12);
  assert.equal(d.level, 0); assert.equal(d.vibrate, false);
  breaks += Number(feed(f, 90, at + 6000).breakEvent);
  assert.equal(breaks, 1);
});

console.log(`PASS: ${checks} low-score rule groups`);
