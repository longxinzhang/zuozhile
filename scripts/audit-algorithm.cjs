#!/usr/bin/env node
// Executable reproductions of known limitations, not accuracy/acceptance tests.
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '../entry/src/main/ets');
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app';
const ts = require(path.join(sdk, 'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const cache = new Map();
function load(name) {
  const file = path.resolve(root, name + '.ets');
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} };
  cache.set(file, module);
  const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
    compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
  }).outputText;
  vm.runInNewContext(code, { module, exports: module.exports, Date,
    require: dep => load(path.relative(root, path.resolve(path.dirname(file), dep))) });
  return module.exports;
}
const { PostureLevel, PostureAlertType, ReminderAction } = load('models/PostureTypes');
const { evaluatePosture } = load('models/PostureEvaluator');
const { buildCalibrationProfile, inspectCalibrationSamples } = load('models/PostureCalibration');
const { computeTodayStats } = load('models/SessionStats');
const copy = value => JSON.parse(JSON.stringify(value));
const healthy = { timestamp: Date.now(), skeleton: {
  nose: { x: 200, y: 190, score: 1 }, leftShoulder: { x: 100, y: 300, score: 1 },
  rightShoulder: { x: 300, y: 300, score: 1 }
}, face: { yaw: 0, pitch: 0, roll: 0, confidence: 1, mouthOpenRatio: .16, mouthAvailable: false,
  rect: { left: 180, top: 140, width: 40, height: 60 } } };
const profile = buildCalibrationProfile(Array.from({ length: 5 }, () => copy(healthy)));
const faceOnly = copy(healthy);
faceOnly.skeleton = {};
assert.equal(evaluatePosture(faceOnly, profile).sit.level, PostureLevel.GOOD);
console.log('CONFIRMED: shoulders absent + level face is labelled GOOD/shoulders stable');

const compressed = copy(healthy);
compressed.skeleton.leftShoulder.x = 140;
compressed.skeleton.rightShoulder.x = 260;
assert.equal(evaluatePosture(compressed, profile).sit.alertType, PostureAlertType.ITEM_01);
const turning = copy(compressed);
turning.face.yaw = 45;
assert.equal(JSON.stringify(evaluatePosture(compressed, profile).sit),
  JSON.stringify(evaluatePosture(turning, profile).sit));
console.log('CONFIRMED: shoulder compression triggers rounded-shoulder alert without a yaw gate');

const down = copy(healthy), up = copy(healthy);
down.face.pitch = -35;
up.face.pitch = 35;
assert.equal(evaluatePosture(down, profile).chin.label, evaluatePosture(up, profile).chin.label);
console.log('CONFIRMED: opposite pitch deviations share the same head-down label');

const moving = Array.from({ length: 10 }, (_, i) => {
  const frame = copy(healthy);
  frame.face.pitch = i % 2 ? 35 : -35;
  return frame;
});
assert.equal(inspectCalibrationSamples(moving).isUsable, true);
console.log('CONFIRMED: high-confidence moving calibration passes without a stability check');

const missing = copy(healthy);
missing.skeleton = {};
missing.face.confidence = 0;
const result = evaluatePosture(missing, profile);
const record = { timestamp: Date.now(), score: result.score, sitLevel: result.sit.level,
  chinLevel: result.chin.level, mouthLevel: result.mouth.level, action: ReminderAction.NONE,
  alertType: PostureAlertType.NONE };
assert.equal(computeTodayStats([record], 2000).uprightCount, 1);
console.log('CONFIRMED: all-UNKNOWN record is counted as upright in statistics');
const records = Array.from({ length: 60 }, () => ({ ...record }));
assert.equal(computeTodayStats(records, 2000).guardedMinutes, 2);
assert.equal(computeTodayStats(records, 5000).guardedMinutes, 5);
console.log('CONFIRMED: changing current sampling interval changes historical duration from 2 to 5 minutes');

const both = copy(compressed);
both.face.mouthAvailable = true;
both.face.jawOpen = .5;
both.face.lipGapRatio = .1;
profile.neutralLipGapRatio = .08;
const multiple = evaluatePosture(both, profile);
assert.equal(multiple.mouth.alertType, PostureAlertType.ITEM_11);
assert.equal(multiple.activeAlerts.includes(PostureAlertType.ITEM_11), false);
console.log('CONFIRMED: lower-priority mouth event is discarded before reminder state accumulation');
