#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app';
const ts = require(path.join(sdk, 'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const file = path.join(root, 'entry/src/main/ets/services/ARPostureSource.ets');
const code = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }
}).outputText;

function setup() {
  const calls = [];
  const state = { nativeFaces: 1, coreFaces: 1, jaw: .6, gap: .08, confidence: .99, yaw: 0, pitch: 0,
    startError: false, captureError: false, detectorError: false };
  const native = {
    start() { calls.push('start'); if (state.startError) throw new Error('unsupported'); },
    async capture() {
      calls.push('capture');
      if (state.captureError) throw new Error('camera error');
      return { rgba: new ArrayBuffer(16), width: 2, height: 2, jawOpen: state.jaw, lipGapRatio: state.gap,
        faceCount: state.nativeFaces, timestampMs: 1234 };
    },
    stop() { calls.push('stop'); }
  };
  const module = { exports: {} };
  const dependencies = {
    '@kit.CameraKit': { camera: { CameraPosition: { CAMERA_POSITION_FRONT: 1 }, getCameraManager: () => ({
      getSupportedCameras: () => [{ cameraPosition: 1, cameraOrientation: 270 }]
    }) } },
    '@kit.ImageKit': { image: { PixelMapFormat: { RGBA_8888: 3 }, async createPixelMap() {
      calls.push('pixelMap');
      return { async rotate(angle) { calls.push(`rotate:${angle}`); }, async release() { calls.push('releasePixelMap'); } };
    } } },
    '@kit.PerformanceAnalysisKit': { hilog: { info() {}, warn() {} } },
    'libposture_ar.so': native,
    './CoreVisionPostureDetector': { CoreVisionPostureDetector: class {
      async prepare() { calls.push('prepare'); }
      async detect() {
        calls.push('detect');
        if (state.detectorError) throw new Error('inference failed');
        return { timestamp: 1234, skeleton: {}, face: { confidence: state.confidence,
          yaw: state.yaw, pitch: state.pitch, roll: 0, mouthOpenRatio: 0, mouthAvailable: false } };
      }
      faceCount() { return state.coreFaces; }
      statusDetail() { return 'core vision'; }
      async release() { calls.push('releaseDetector'); }
    } },
    './CoreVisionPostureSource': { CoreVisionPostureSource: class {
      async sample() { calls.push('fallback'); return { face: { mouthAvailable: false } }; }
      async dispose() { calls.push('disposeFallback'); }
      status() { return { detail: 'photo source' }; }
    } },
    './PostureSource': { PostureSourceKind: { CORE_VISION: 'coreVision' } }
  };
  vm.runInNewContext(code, { module, exports: module.exports, require(name) {
    assert.ok(dependencies[name], 'Unexpected dependency: ' + name); return dependencies[name];
  } });
  return { source: new module.exports.ARPostureSource({}, 'surface'), calls, state };
}

async function main() {
  const { source, state, calls } = setup();
  let sample = await source.sample({});
  assert.equal(sample.face.mouthAvailable, true);
  assert.equal(sample.face.jawOpen, .6);
  assert.deepEqual(calls, ['start', 'prepare', 'capture', 'pixelMap', 'rotate:270', 'detect', 'releasePixelMap']);
  for (const patch of [{ nativeFaces: 0 }, { nativeFaces: 2 }, { coreFaces: 2 }, { confidence: .7 },
    { yaw: 36 }, { pitch: -31 }, { jaw: -1 }, { jaw: NaN }, { jaw: 1.01 }, { gap: -1 }, { gap: NaN }]) {
    Object.assign(state, { nativeFaces: 1, coreFaces: 1, confidence: .99, yaw: 0, pitch: 0, jaw: .6, gap: .08 }, patch);
    sample = await source.sample({});
    assert.equal(sample.face.mouthAvailable, false, JSON.stringify(patch));
  }
  state.captureError = true;
  await assert.rejects(source.sample({}), /camera error/);
  assert.ok(!calls.includes('fallback'), 'Cannot mix camera geometry after a successful frame');
  await source.dispose();
  assert.equal(calls.filter(x => x === 'stop').length, 1);
  await source.dispose();
  assert.equal(calls.filter(x => x === 'stop').length, 1);

  for (const failure of ['startError', 'captureError', 'detectorError']) {
    const test = setup();
    test.state[failure] = true;
    const sample = await test.source.sample({});
    assert.equal(sample.face.mouthAvailable, false);
    assert.equal(test.calls.filter(x => x === 'start').length, 1);
    if (failure !== 'startError') assert.ok(test.calls.indexOf('stop') < test.calls.indexOf('fallback'));
    if (failure === 'detectorError') assert.ok(test.calls.includes('releasePixelMap'));
    await test.source.sample({});
    assert.equal(test.calls.filter(x => x === 'start').length, 1, 'Fallback must not fight over camera');
    await test.source.dispose();
  }
  console.log('PASS: same-frame native mouth integration, pose/confidence/multi-person gates, startup fallback, failure and disposal');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
