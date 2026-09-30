#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const root = path.resolve(__dirname, '..');
const sdk = process.env.DEVECO_HOME || '/Applications/DevEco-Studio.app';
const ts = require(path.join(sdk, 'Contents/sdk/default/openharmony/ets/build-tools/ets-loader/node_modules/typescript'));
const read = file => fs.readFileSync(path.join(root, 'entry/src/main/ets', file + '.ets'), 'utf8');
const compilerOptions = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS };
function load(file, dependencies = {}) {
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(read(file), { compilerOptions }).outputText,
    { module, exports: module.exports, require(name) {
      if (name in dependencies) return dependencies[name];
      if (name.startsWith('.')) return load(path.posix.join(path.posix.dirname(file), name), dependencies);
      throw Error('Unexpected dependency: ' + name);
    } });
  return module.exports;
}
function methods(file, name) {
  const ast = ts.createSourceFile('Source.ts', read(file).replaceAll('struct ', 'class '), ts.ScriptTarget.Latest, true);
  const component = ast.statements.find(n => ts.isClassDeclaration(n) && n.name.text === name);
  return component.members.filter(ts.isMethodDeclaration).filter(n => n.name.text !== 'build' && !/^@Builder\b/.test(n.getText(ast)))
    .map(n => n.getText(ast)).join('\n');
}
function methodClass(file, name, dependencies) {
  const source = `class Subject { ${methods(file, name)} } module.exports = Subject;`;
  const module = { exports: {} };
  vm.runInNewContext(ts.transpileModule(source, { compilerOptions }).outputText,
    { module, Date, Math, ...dependencies });
  return module.exports;
}
const geometry = load('debug/SkeletonGeometry');
const joint = (type, x, y, confidence = .95) => ({ type, x, y, confidence });
const raw = [joint(5, 160, 220), joint(6, 480, 220), joint(7, 120, 330), joint(9, 100, 450),
  joint(8, 530, 300, .1), joint(10, 610, 400), joint(11, 200, 620), joint(12, 430, 620)];
const point = (x, y) => ({ x, y });
const near = (a, b) => assert.ok(Math.abs(a - b) < 1e-8, `${a} != ${b}`);
for (const [w, h] of [[720, 1280], [1280, 720], [480, 480]]) {
  for (const [vw, vh] of [[300, 400], [320, 240], [480, 640], [80, 110]]) {
    for (const p of [point(0, 0), point(w / 2, h / 2), point(w, h), point(w * .17, h * .83)]) {
      const a = geometry.projectJoint(p, w, h, vw, vh, false);
      const b = geometry.projectJoint(p, w, h, vw, vh, true);
      near(a.x + b.x, vw); near(a.y, b.y);
      assert.ok(a.x >= 0 && a.x <= vw && a.y >= 0 && a.y <= vh);
    }
  }
}
const centered = geometry.projectJoint(point(0, 0), 720, 1280, 300, 400, false);
near(centered.x, 37.5); near(centered.y, 0);
const invalid = [joint(-1, 20, 20), joint(17, 20, 20), joint(1.5, 20, 20), joint(1, -1, 20),
  joint(1, NaN, 20), joint(1, 800, 20), joint(1, 20, 1500), joint(1, 20, 20, Infinity), joint(1, 20, 20, 1.1)];
assert.equal(geometry.visibleJoints(invalid, 720, 1280).length, 0);
assert.equal(geometry.visibleJoints(raw, 0, 1280).length, 0);
assert.equal(geometry.visibleJoints([joint(5, 10, 20, .5), joint(5, 30, 40, .9)], 720, 1280).length, 1);
assert.equal(geometry.visibleJoints([joint(5, 10, 20, .5), joint(5, 30, 40, .9)], 720, 1280)[0].x, 30);
const drawing = geometry.skeletonDrawing(raw, 720, 1280, 300, 400, true);
assert.equal(drawing.joints.length, 7);
assert.equal(drawing.bones.length, 6, 'Missing elbow must not be replaced with a shoulder-to-wrist bone');
assert.equal(geometry.skeletonDrawing(raw, 0, 1280, 300, 400, false).bones.length, 0);
const sdkEnum = fs.readFileSync(path.join(sdk, 'Contents/sdk/default/hms/ets/api/@hms.ai.vision.skeletonDetection.d.ts'), 'utf8');
for (const [name, value] of Object.entries({ NOSE: 0, LEFT_EYE: 1, RIGHT_EYE: 2, LEFT_EAR: 3, RIGHT_EAR: 4,
  LEFT_SHOULDER: 5, RIGHT_SHOULDER: 6, LEFT_ELBOW: 7, RIGHT_ELBOW: 8, LEFT_WRIST: 9, RIGHT_WRIST: 10,
  LEFT_HIP: 11, RIGHT_HIP: 12, LEFT_KNEE: 13, RIGHT_KNEE: 14, LEFT_ANKLE: 15, RIGHT_ANKLE: 16 })) {
  assert.match(sdkEnum, new RegExp(`${name} = ${value}\\b`));
}
console.log('PASS: SDK 17-point ordering, contain projection, portrait/landscape/square, mirroring and unreliable joint rejection');

const utilSdk = fs.readFileSync(path.join(sdk, 'Contents/sdk/default/openharmony/ets/api/@ohos.util.d.ts'), 'utf8');
assert.match(utilSdk, /encodeToString\(src: Uint8Array[^)]*\): Promise<string>/,
  'Base64 mock must match the asynchronous SDK contract');

function feedSetup() {
  const state = { packed: 0, released: 0, packError: false, releaseError: false, deferred: undefined,
    base64Error: false, base64Deferred: undefined, base64Started: undefined };
  const feed = load('services/SkeletonDebugFeed', {
    '@kit.ImageKit': { image: { createImagePacker: () => ({
      async packToData(pixelMap, options) {
        assert.equal(pixelMap, pixels); assert.equal(options.format, 'image/jpeg'); state.packed++;
        if (state.packError) throw Error('encoding error');
        if (state.deferred) await state.deferred;
        return new Uint8Array([1, 2, 3]).buffer;
      },
      async release() { state.released++; if (state.releaseError) throw Error('release error'); }
    }) } },
    '@kit.ArkTS': { util: { Base64Helper: class {
      async encodeToString(bytes) {
        state.base64Started?.();
        if (state.base64Deferred) await state.base64Deferred;
        if (state.base64Error) throw Error('base64 error');
        return Buffer.from(bytes).toString('base64');
      }
    } } }
  }).SkeletonDebugFeed;
  const pixels = { getImageInfoSync: () => ({ size: { width: 720, height: 1280 } }) };
  const skeleton = { points: raw.map(p => ({ type: p.type, point: { x: p.x, y: p.y }, score: p.confidence })) };
  return { feed, state, pixels, skeleton };
}

async function main() {
  const { feed, state, pixels, skeleton } = feedSetup();
  const received = [];
  await feed.publish(0, { getImageInfoSync() { throw Error('disabled must not read pixels'); } }, skeleton, 1, 100);
  let token = feed.connect((frame, error) => received.push({ frame, error }), false);
  await feed.publish(token, pixels, skeleton, 2, 1234);
  assert.equal(state.packed, 0); assert.equal(received.length, 1);
  assert.equal(received[0].frame.people, 2); assert.equal(received[0].frame.points.length, 7);
  assert.equal(received[0].frame.timestamp, 1234); assert.equal(received[0].frame.imageUrl, '');
  received[0].frame.points[0].x = 9999;
  assert.equal(skeleton.points[0].point.x, 160, 'Debug consumer cannot mutate the detection result');
  feed.disconnect(token);
  token = feed.connect((frame, error) => received.push({ frame, error }), true);
  await feed.publish(token, pixels, skeleton, 1, 2345);
  assert.equal(received.at(-1).frame.imageUrl, 'data:image/jpeg;base64,AQID');
  assert.equal(state.packed, 1); assert.equal(state.released, 1);
  state.base64Error = true;
  await feed.publish(token, pixels, skeleton, 1, 2456);
  assert.equal(received.at(-1).frame.imageError, true);
  assert.equal(received.at(-1).frame.imageUrl, '');
  assert.equal(received.at(-1).frame.points.length, 7);
  assert.equal(state.released, 2);
  state.base64Error = false;
  state.packError = true;
  await feed.publish(token, pixels, skeleton, 1, 3456);
  assert.equal(received.at(-1).frame.imageError, true); assert.equal(received.at(-1).frame.imageUrl, '');
  assert.equal(received.at(-1).frame.points.length, 7); assert.equal(state.released, 3);
  state.packError = false;
  let complete;
  state.deferred = new Promise(resolve => { complete = resolve; });
  const inFlight = feed.publish(token, pixels, skeleton, 1, 4567);
  const count = received.length;
  feed.disconnect(token);
  const nextToken = feed.connect((frame, error) => received.push({ frame, error }), false);
  feed.disconnect(token);
  assert.equal(feed.session(), nextToken, 'An old view cannot unsubscribe the new view');
  complete(); await inFlight;
  assert.equal(received.length, count, 'Closed or replaced view must discard in-flight images');
  await feed.publish(0, pixels, skeleton, 1, 5678);
  assert.equal(received.length, count, 'Frame started before opt-in must not leak into the new view');
  state.deferred = undefined;
  const base64Started = new Promise(resolve => { state.base64Started = resolve; });
  state.base64Deferred = new Promise(resolve => { complete = resolve; });
  token = feed.connect((frame, error) => received.push({ frame, error }), true);
  const encoding = feed.publish(token, pixels, skeleton, 1, 5789);
  await base64Started;
  assert.equal(received.length, count, 'Frame must wait for asynchronous Base64 encoding');
  feed.disconnect(token);
  complete(); await encoding;
  assert.equal(received.length, count, 'Disconnect during Base64 encoding must discard the result');
  state.base64Deferred = undefined;
  state.base64Started = undefined;
  console.log('PASS: asynchronous Base64 result, rejection and disconnect during encoding match the real SDK');
  token = feed.connect(() => { throw Error('UI failure'); }, false);
  await feed.publish(token, pixels, skeleton, 1, 6789);
  feed.fail('test'); feed.disconnect(token);
  assert.equal(feed.session(), 0);
  assert.doesNotMatch(read('services/SkeletonDebugFeed'), /fileIo|fs\.|writeFile|http|request\.fetch|preferences/);
  console.log('PASS: default-off feed, no image encoding in skeleton mode, atomic same-frame image/points, cleanup, stale rejection and exception isolation');

  const timers = new Map(); let nextTimer = 0;
  const Panel = methodClass('components/SkeletonDebugPanel', 'SkeletonDebugPanel', {
    SkeletonDebugFeed: feed, setInterval: callback => { timers.set(++nextTimer, callback); return nextTimer; },
    clearInterval: id => timers.delete(id)
  });
  const panel = Object.assign(new Panel(), { active: true, realSource: true, isMonitoring: true, withImage: true,
    frame: undefined, error: '', busy: false, locked: false, guarding: false, intervalMs: 2000, token: 0, timer: -1 });
  panel.connect(); assert.equal(feed.session(), panel.token); assert.equal(timers.size, 1);
  panel.frame = { timestamp: Date.now() - 10000 }; panel.guarding = true;
  timers.get(panel.timer)(); assert.equal(panel.frame, undefined); assert.match(panel.error, /过期/);
  panel.frame = { timestamp: Date.now() - 10000 }; panel.guarding = false;
  timers.get(panel.timer)(); assert.ok(panel.frame, 'Single-frame inspection can retain an explicitly dated still');
  panel.active = false; panel.availabilityChanged();
  assert.equal(feed.session(), 0); assert.equal(panel.frame, undefined); assert.equal(timers.size, 0);
  assert.equal(panel.isMonitoring, false); assert.equal(panel.withImage, false);
  panel.active = true; panel.isMonitoring = true; panel.connect(); panel.aboutToDisappear();
  assert.equal(feed.session(), 0); assert.equal(timers.size, 0);
  console.log('PASS: tab/background/source changes and disappearing views clear the feed, image state and timer; stale guard frames clear');

  const Page = methodClass('pages/Index', 'Index', { SkeletonDebugFeed: feed });
  function page() {
    const calls = [];
    const p = Object.assign(new Page(), { pageRunId: 1, isManualOperation: false, isStartingGuard: false,
      isStoppingGuard: false, isSampling: false, isGuarding: false, appForeground: true,
      settings: { useCoreVision: true, profile: {} },
      prepareSourceAccess: async () => { calls.push('prepare'); return true; },
      rebuildPostureSource: async () => { calls.push('rebuild'); },
      releasePostureSource: async () => { calls.push('release'); },
      postureSource: { sample: async () => { calls.push('sample'); return {}; } }
    });
    return { p, calls };
  }
  token = feed.connect(() => {}, false);
  let { p, calls } = page();
  await p.sampleSkeletonOnce(); assert.deepEqual(calls, ['prepare', 'rebuild', 'sample', 'release']);
  assert.equal(p.isManualOperation, false);
  for (const patch of [{ isManualOperation: true }, { isStartingGuard: true }, { isStoppingGuard: true },
    { isSampling: true }, { isGuarding: true }, { appForeground: false }, { settings: { useCoreVision: false } }]) {
    const test = page(); Object.assign(test.p, patch); await test.p.sampleSkeletonOnce(); assert.equal(test.calls.length, 0);
  }
  ({ p, calls } = page());
  p.prepareSourceAccess = async () => { p.appForeground = false; return true; };
  await p.sampleSkeletonOnce(); assert.equal(calls.length, 0); assert.equal(p.isManualOperation, false);
  ({ p, calls } = page());
  p.postureSource.sample = async () => { calls.push('sample'); throw Error('camera failed'); };
  await p.sampleSkeletonOnce(); assert.equal(calls.at(-1), 'release'); assert.equal(p.isManualOperation, false);
  ({ p, calls } = page());
  p.releasePostureSource = async () => { throw Error('release failed'); };
  await p.sampleSkeletonOnce(); assert.equal(p.isManualOperation, false);
  feed.disconnect(token);
  const body = methods('pages/Index', 'Index').split('private async sampleSkeletonOnce')[1].split('private createPostureSource')[0];
  assert.doesNotMatch(body, /evaluatePosture|appendRecord|persistData|applyResult|runCalibration|reminder\.feed/);
  console.log('PASS: isolated one-frame capture, busy/background gates, failure cleanup; no statistics, baseline or scoring writes');

  const colors = [];
  const ctx = { width: 300, height: 400, clearRect() { colors.length = 0; }, beginPath() {}, moveTo() {},
    lineTo() {}, stroke() {}, arc(x, y) { colors.push([x, y]); }, fill() {} };
  const View = methodClass('components/SkeletonDebugPanel', 'SkeletonFrameView', geometry);
  const view = Object.assign(new View(), { ready: true, context: ctx, mirrored: false, imageReady: false,
    imageFailed: false, frame: { imageUrl: 'data:image/jpeg;base64,AQID', width: 720, height: 1280, points: raw } });
  view.draw(); assert.equal(colors.length, 0, 'Never paint new joints until the same image is ready');
  view.imageReady = true; view.draw(); assert.equal(colors.length, 7);
  const first = colors.map(p => [...p]); view.mirrored = true; view.draw();
  first.forEach((p, i) => { near(p[0] + colors[i][0], 300); near(p[1], colors[i][1]); });
  console.log('PASS: actual Canvas drawing waits for its matching image and mirrors correctly');

  const skeletonTypes = Object.fromEntries([...sdkEnum.matchAll(/\b([A-Z_]+) = (\d+)/g)]
    .map(match => [match[1], Number(match[2])]));
  const callsToSDK = [];
  const primary = { ...skeleton, score: .99, boundingBox: { width: 420, height: 600 } };
  const weak = { points: [], score: .1, boundingBox: { width: 10, height: 10 } };
  const face = { probability: .98, pose: { yaw: 5, pitch: -2, roll: 1 },
    rect: { left: 100, top: 100, width: 60, height: 80 }, points: [] };
  const Detector = load('services/CoreVisionPostureDetector', {
    './SkeletonDebugFeed': { SkeletonDebugFeed: feed },
    '@kit.CoreVisionKit': {
      skeletonDetection: { SkeletonPointType: skeletonTypes, SkeletonDetector: { create: async () => ({
        process: async request => { callsToSDK.push(request.inputData.pixelMap); return { skeletons: [weak, primary] }; },
        destroy: async () => {}
      }) } },
      faceDetector: { init: async () => true, detect: async request => { callsToSDK.push(request.pixelMap); return [face]; },
        release: async () => {} }
    }
  }).CoreVisionPostureDetector;
  const detector = new Detector();
  const before = JSON.stringify({ primary, face });
  const plain = await detector.detect(pixels);
  let observed;
  token = feed.connect(frame => { observed = frame; }, false);
  const inspected = await detector.detect(pixels);
  assert.equal(JSON.stringify({ ...plain, timestamp: 0 }), JSON.stringify({ ...inspected, timestamp: 0 }));
  assert.equal(observed.timestamp, inspected.timestamp);
  assert.equal(observed.people, 2); assert.equal(observed.points.length, 7);
  assert.equal(JSON.stringify({ primary, face }), before, 'Debugging must not mutate raw SDK inputs');
  assert.equal(callsToSDK.length, 4); assert.ok(callsToSDK.every(frame => frame === pixels));
  feed.disconnect(token); await detector.release();
  console.log('PASS: real detector method returns identical posture data with debugging on/off and runs no extra inference');
}
main().catch(error => { console.error(error); process.exitCode = 1; });
