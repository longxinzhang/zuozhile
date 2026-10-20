#!/usr/bin/env node
'use strict';
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { typescript: ts } = require('./deveco-sdk.cjs');
const sourceRoot = path.resolve(__dirname, '../entry/src/main/ets');
const compiled = new Map();
const tests = [];
const YUV = 1003;
const RGBA = 3;
const NV21 = 8;
const FRONT = 2;
const PHOTO = 1;
let fixtures;
const plain = value => JSON.parse(JSON.stringify(value));
const test = (name, run) => tests.push({ name, run });
const profile = (width, height, format = YUV) => ({ format, size: { width, height } });
const point = (type, x, y, score = .9) => ({ type, point: { x, y }, score });
const skeleton = (score, points = [point(5, 20, 30)]) => ({ score, points });
const flush = async () => { for (let i = 0; i < 100; i++) await Promise.resolve(); };

function deferred() {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  return { promise, resolve, reject };
}

function tracked(promise) {
  const state = { settled: false, value: undefined, error: undefined };
  Promise.resolve(promise).then(value => Object.assign(state, { settled: true, value }),
    error => Object.assign(state, { settled: true, error }));
  return state;
}

async function completed(promise, label = 'Operation') {
  const state = tracked(promise);
  await flush();
  assert.equal(state.settled, true, label + ' must settle without native calls or real timers');
  if (state.error) throw state.error;
  return state.value;
}

async function rejected(promise, pattern) {
  const state = tracked(promise);
  await flush();
  assert.equal(state.settled, true, 'Expected rejection must settle');
  assert.ok(state.error, 'Expected rejection, received ' + JSON.stringify(state.value));
  assert.match(String(state.error), pattern);
  return state.error;
}

class Clock {
  constructor() {
    this.time = 10000;
    this.wall = Date.UTC(2026, 9, 19, 9);
    this.tasks = new Map();
    this.history = [];
    this.nextId = 0;
  }

  add(callback, delay, interval) {
    assert.equal(typeof callback, 'function');
    assert.ok(Number.isFinite(delay) && delay >= 0);
    const id = ++this.nextId;
    this.tasks.set(id, { id, callback, delay, interval, due: this.time + delay });
    this.history.push({ id, delay, interval });
    return id;
  }

  globals() {
    const clock = this;
    return {
      Date: class extends Date { static now() { return clock.wall; } },
      performance: { now: () => clock.time },
      setInterval: (callback, delay) => this.add(callback, delay, true),
      clearInterval: id => this.tasks.delete(id),
      setTimeout: (callback, delay) => this.add(callback, delay, false),
      clearTimeout: id => this.tasks.delete(id)
    };
  }

  async advance(elapsed) {
    assert.ok(elapsed >= 0);
    const target = this.time + elapsed;
    await flush();
    let ticks = 0;
    while (true) {
      const next = [...this.tasks.values()].filter(task => task.due <= target)
        .sort((a, b) => a.due - b.due || a.id - b.id)[0];
      if (!next) break;
      assert.ok(++ticks < 20000, 'Timer loop must remain bounded');
      this.wall += next.due - this.time;
      this.time = next.due;
      if (next.interval) next.due += Math.max(1, next.delay);
      else this.tasks.delete(next.id);
      next.callback();
      await flush();
    }
    this.wall += target - this.time;
    this.time = target;
    await flush();
  }
}

function setup(options = {}) {
  const f = { clock: new Clock(), calls: [], resources: [], gates: new Map(), allGates: [],
    faults: new Map(), violations: [], queue: [], allowed: true, reading: 0, maxReading: 0,
    processing: 0, maxProcessing: 0, processed: [], packed: [], encoded: [], imports: [],
    config: { profiles: [profile(640, 480)], device: { cameraPosition: FRONT }, scenes: [PHOTO],
      display: 0, rotation: 0, physical: true, compression: true, receiverAvailable: true,
      detectorAvailable: true, surface: 'mock-preview-surface', canAddInput: true, canAddOutput: true,
      skeletons: [skeleton(.95)], ...options } };
  fixtures.push(f);
  f.current = () => f.allowed;
  f.count = name => f.calls.filter(call => call.name === name).length;
  f.forbid = message => { f.violations.push(message); throw Error(message); };
  f.check = (condition, message) => { if (!condition) f.forbid(message); };
  f.strict = (object, label) => new Proxy(object, { get(target, key) {
    if (!(key in target)) return f.forbid('Unexpected ' + label + '.' + String(key));
    return target[key];
  } });
  f.record = (name, args) => f.calls.push({ name, args });
  f.fault = name => {
    const failures = f.faults.get(name);
    if (failures?.length) throw Error(failures.shift());
  };
  f.failOnce = (name, message = name + ' failed') => {
    if (!f.faults.has(name)) f.faults.set(name, []);
    f.faults.get(name).push(message);
  };
  f.block = name => {
    assert.equal(f.gates.has(name), false);
    const gate = deferred();
    f.gates.set(name, gate);
    f.allGates.push(gate);
    return gate;
  };
  f.sync = (name, args, value) => {
    f.record(name, args);
    f.fault(name);
    return typeof value === 'function' ? value() : value;
  };
  f.step = async (name, args, value) => {
    f.record(name, args);
    const gate = f.gates.get(name);
    f.gates.delete(name);
    if (gate) await gate.promise;
    f.fault(name);
    return typeof value === 'function' ? value() : value;
  };
  f.resource = (kind, end, after = () => {}) => {
    const resource = { kind, end, released: false, attempts: 0, handlers: new Map(), callbacks: new Map() };
    resource[end] = async () => {
      f.check(!resource.released, kind + '.' + end + ' released a successful resource twice');
      f.check(!(kind === 'ImageReceiver' && f.reading) && !(kind === 'SkeletonDetector' && f.processing),
        kind + '.' + end + ' must wait for its in-flight native work');
      resource.attempts++;
      await f.step(kind + '.' + end, [resource], () => { resource.released = true; after(); });
    };
    resource.on = (event, ...args) => {
      f.check(typeof args.at(-1) === 'function', kind + '.on requires a callback');
      f.sync(kind + '.on', [event, ...args], () => {
        resource.handlers.set(event, args.at(-1));
        resource.callbacks.set(event, args.at(-1));
      });
    };
    resource.off = (event, ...args) => {
      f.check(resource.callbacks.get(event) === args.at(-1), kind + '.off must use its original callback');
      f.sync(kind + '.off', [event, ...args], () => resource.handlers.delete(event));
    };
    f.resources.push(resource);
    return resource;
  };
  const guarded = (value, label) => {
    if (!value || typeof value !== 'object') return value;
    return new Proxy(value, {
      get: (target, key) => guarded(target[key], label + '.' + String(key)),
      set: () => f.forbid(label + ' mutation'),
      deleteProperty: () => f.forbid(label + ' deletion'),
      defineProperty: () => f.forbid(label + ' replacement')
    });
  };
  const scoring = { score: 87, records: [{ score: 91, timestamp: 123 }],
    settings: { useCoreVision: false, profile: { shoulderWidth: 120 } }, reminder: 'unchanged' };
  const beforeScoring = plain(scoring);
  f.context = guarded(scoring, 'scoring context');
  const manager = f.strict({
    getCameraDevice: (position, type) => {
      f.check(position === FRONT && type === 0, 'Select the current default front camera');
      return f.sync('CameraManager.getCameraDevice', [position, type], f.config.device);
    },
    getSupportedSceneModes: device => f.sync('CameraManager.getSupportedSceneModes', [device], f.config.scenes),
    getSupportedFullOutputCapability: (device, scene) => {
      f.check(device === f.config.device && scene === PHOTO, 'Use the front NORMAL_PHOTO capability');
      return f.sync('CameraManager.getSupportedFullOutputCapability', [device, scene],
        f.strict({ previewProfiles: f.config.profiles }, 'preview capability'));
    },
    createCameraInput: device => f.sync('CameraManager.createCameraInput', [device], () => {
      f.check(device === f.config.device, 'Input must belong to the selected front camera');
      const input = f.input = f.resource('CameraInput', 'close');
      input.open = () => f.step('CameraInput.open', [], undefined);
      input.isPhysicalCameraOrientationVariable = () => f.sync('CameraInput.isPhysicalCameraOrientationVariable', [], f.config.physical);
      input.usePhysicalCameraOrientation = value => f.sync('CameraInput.usePhysicalCameraOrientation', [value], undefined);
      return input;
    }),
    createPreviewOutput: (selected, surface) => f.sync('CameraManager.createPreviewOutput', [selected, surface], () => {
      f.check(f.config.profiles.includes(selected), 'Preview must use an advertised profile');
      f.check(surface === f.config.surface && surface.length > 0, 'Preview must use the receiver surface');
      f.selected = selected;
      const preview = f.preview = f.resource('PreviewOutput', 'release');
      preview.isBandwidthCompressionSupported = () => f.sync('PreviewOutput.isBandwidthCompressionSupported', [], f.config.compression);
      preview.enableBandwidthCompression = value => f.sync('PreviewOutput.enableBandwidthCompression', [value], undefined);
      preview.getPreviewRotation = value => f.sync('PreviewOutput.getPreviewRotation', [value], f.config.rotation);
      return preview;
    }),
    createSession: scene => f.sync('CameraManager.createSession', [scene], () => {
      f.check(scene === PHOTO, 'Use a continuous preview session, not AR or photo capture');
      const session = f.session = f.resource('Session', 'release');
      for (const name of ['beginConfig', 'addInput', 'addOutput']) {
        session[name] = (...args) => f.sync('Session.' + name, args, undefined);
      }
      session.canAddInput = input => f.sync('Session.canAddInput', [input], f.config.canAddInput);
      session.canAddOutput = output => f.sync('Session.canAddOutput', [output], f.config.canAddOutput);
      for (const name of ['commitConfig', 'start', 'stop']) session[name] = () => f.step('Session.' + name, [], undefined);
      return session;
    })
  }, 'CameraManager');
  const camera = f.strict({ CameraPosition: { CAMERA_POSITION_FRONT: FRONT },
    CameraType: { CAMERA_TYPE_DEFAULT: 0 }, CameraFormat: { CAMERA_FORMAT_YUV_420_SP: YUV },
    SceneMode: { NORMAL_PHOTO: PHOTO }, getCameraManager: context => {
      f.check(context === f.context, 'Camera manager must use the supplied context');
      return f.sync('camera.getCameraManager', [context], manager);
    } }, 'CameraKit');
  const image = f.strict({ PixelMapFormat: { NV21, RGBA_8888: RGBA }, ComponentType: { JPEG: 4 },
    createImageReceiver: receiverOptions => f.sync('image.createImageReceiver', [receiverOptions], () => {
      if (!f.config.receiverAvailable) return undefined;
      f.receiverOptions = plain(receiverOptions);
      const receiver = f.receiver = f.resource('ImageReceiver', 'release');
      receiver.getReceivingSurfaceId = () => f.step('ImageReceiver.getReceivingSurfaceId', [], f.config.surface);
      receiver.readLatestImage = async () => {
        f.maxReading = Math.max(f.maxReading, ++f.reading);
        try {
          return await f.step('ImageReceiver.readLatestImage', [], () => {
            const latest = f.queue.pop();
            f.queue.length = 0;
            if (latest) latest.delivered = true;
            return latest;
          });
        } finally { f.reading--; }
      };
      return receiver;
    }),
    createPixelMap: (buffer, pixelOptions) => f.step('image.createPixelMap', [buffer, pixelOptions], () => {
      f.check(pixelOptions.srcPixelFormat === NV21 && pixelOptions.pixelFormat === RGBA && pixelOptions.editable,
        'NV21 must explicitly convert to editable RGBA');
      const pixel = f.resource('PixelMap', 'release');
      pixel.bytes = new Uint8Array(buffer).slice();
      pixel.size = plain(pixelOptions.size);
      pixel.rotate = angle => f.step('PixelMap.rotate', [pixel, angle], () => {
        f.check(!pixel.released, 'Cannot rotate released pixels');
        pixel.rotation = angle;
        if (Math.abs(angle % 180) === 90) pixel.size = { width: pixel.size.height, height: pixel.size.width };
      });
      pixel.getImageInfoSync = () => f.sync('PixelMap.getImageInfoSync', [pixel],
        f.config.info ?? { size: pixel.size, pixelFormat: RGBA });
      return pixel;
    }),
    createImagePacker: () => f.sync('image.createImagePacker', [], () => {
      const packer = f.resource('ImagePacker', 'release');
      packer.packToData = (pixel, packingOptions) => f.step('ImagePacker.packToData', [pixel, packingOptions], () => {
        f.check(!pixel.released && pixel === f.processed.at(-1)?.pixel, 'JPEG and skeleton must use the same live rotated PixelMap');
        f.check(packingOptions.format === 'image/jpeg' && packingOptions.quality === 75, 'Use bounded JPEG quality');
        const bytes = new Uint8Array([255, 216, f.processed.length, 255, 217]);
        f.packed.push({ pixel, bytes });
        return bytes.buffer;
      });
      return packer;
    })
  }, 'ImageKit');
  const skeletonDetection = f.strict({ SkeletonDetector: {
    create: () => f.step('SkeletonDetector.create', [], () => {
      if (!f.config.detectorAvailable) return undefined;
      const detector = f.detector = f.resource('SkeletonDetector', 'destroy');
      detector.process = async request => {
        f.check(typeof request === 'object' && !!request.inputData?.pixelMap,
          'Use a plain Core Vision Request object, not a Request constructor');
        const pixel = request.inputData.pixelMap;
        f.check(!pixel.released && pixel.rotation !== undefined, 'Inference must use live, already-rotated pixels');
        f.processed.push({ pixel, size: { ...pixel.size }, rotation: pixel.rotation });
        f.maxProcessing = Math.max(f.maxProcessing, ++f.processing);
        try {
          return await f.step('SkeletonDetector.process', [request], () => ({ skeletons:
            typeof f.config.skeletons === 'function' ? f.config.skeletons(pixel) : f.config.skeletons }));
        } finally { f.processing--; }
      };
      return detector;
    })
  } }, 'CoreVisionKit');
  const dependencies = {
    '@kit.CameraKit': { camera }, '@kit.ImageKit': { image },
     '@kit.CoreVisionKit': { skeletonDetection, visionBase: { Request: false } },
    '@kit.AbilityKit': { common: {} },
    '@kit.ArkTS': { util: { Base64Helper: class {
      constructor() { f.record('Base64Helper.create', []); }
      encodeToString(bytes) {
        f.check(bytes instanceof Uint8Array && Buffer.from(bytes).equals(Buffer.from(f.packed.at(-1)?.bytes ?? [])),
          'Base64 must encode the same JPEG bytes');
        f.encoded.push(bytes);
        return f.step('Base64Helper.encodeToString', [bytes], () => Buffer.from(bytes).toString('base64'));
      }
    } } },
    '@kit.ArkUI': { display: { getDefaultDisplaySync: () => f.sync('display.getDefaultDisplaySync', [], { rotation: f.config.display }) } },
    '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 73 }, getUptime(type, nanoseconds) {
      f.check(type === 73 && nanoseconds === false, 'Use monotonic startup milliseconds');
      return f.clock.time;
    } } }
  };
  const cache = new Map();
  const allowedModules = new Set(['services/LiveSkeletonCameraSource', 'debug/SkeletonGeometry',
    'services/SkeletonDebugFeed', 'models/LiveSkeletonMonitor', 'services/LiveSkeletonController']);
  f.load = file => {
    f.check(allowedModules.has(file), 'Forbidden scoring, persistence, photo or AR module: ' + file);
    if (cache.has(file)) return cache.get(file).exports;
    if (!compiled.has(file)) {
      const filename = path.join(sourceRoot, file + '.ets');
      const result = ts.transpileModule(fs.readFileSync(filename, 'utf8'), { fileName: file + '.ts',
        compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS }, reportDiagnostics: true });
      const errors = (result.diagnostics ?? []).filter(item => item.category === ts.DiagnosticCategory.Error);
      assert.deepEqual(errors.map(item => ts.flattenDiagnosticMessageText(item.messageText, '\n')), []);
      compiled.set(file, result.outputText);
    }
    const module = { exports: {} };
    cache.set(file, module);
    vm.runInNewContext(compiled.get(file), { module, exports: module.exports, Error, Promise, Uint8Array, ArrayBuffer,
      ...f.clock.globals(), canIUse: capability => f.sync('canIUse', [capability], capability !== f.config.missingCapability),
      require(name) {
        f.imports.push(name);
        if (Object.hasOwn(dependencies, name)) return dependencies[name];
        f.check(name.startsWith('.'), 'Unmocked native dependency: ' + name);
        return f.load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)));
      } }, { filename: path.join(sourceRoot, file + '.ets'), timeout: 2000 });
    return module.exports;
  };
  f.feed = f.load('services/SkeletonDebugFeed').SkeletonDebugFeed;
  f.feedEvents = [];
  f.feedToken = f.feed.connect((...args) => f.feedEvents.push(args), true);
  const beforeFeed = { generation: f.feed.generation, sequence: f.feed.sequence, listener: f.feed.listener,
    includeImage: f.feed.includeImage, session: f.feed.session() };
  for (const name of ['connect', 'disconnect', 'publish', 'fail']) f.feed[name] = () => f.forbid('SkeletonDebugFeed.' + name);
  f.source = new (f.load('services/LiveSkeletonCameraSource').LiveSkeletonCameraSource)(f.context);
  f.prepare = () => completed(f.source.prepare(f.current), 'Prepare');
  f.raw = (options = {}) => {
    const { width, height } = f.receiverOptions.size;
    const stride = options.stride ?? width;
    const rows = height * 3 / 2;
    const bytes = new Uint8Array(stride * rows + (options.trailingBytes ?? 0));
    const packed = new Uint8Array(width * rows);
    bytes.fill(237);
    for (let row = 0; row < rows; row++) for (let col = 0; col < width; col++) {
      bytes[row * stride + col] = packed[row * width + col] = (row * 17 + col * 7 + 11) % 251;
    }
    const raw = f.resource('Image', 'release', () => bytes.fill(238));
    Object.assign(raw, { size: { width, height }, format: 25, bytes, packed,
      component: { rowStride: stride, pixelStride: 1, byteBuffer: bytes.buffer } });
    raw.getComponent = type => {
      f.check(type === 4, 'Read the receiver NV21 byte component, not a captured photo');
      return f.step('Image.getComponent', [raw, type], raw.component);
    };
    return raw;
  };
  f.emit = (...images) => {
    const callback = f.receiver?.handlers.get('imageArrival');
    assert.equal(typeof callback, 'function', 'ImageReceiver must be subscribed');
    f.queue.push(...images);
    callback(undefined);
  };
  f.frame = (includeImage = false, raw = f.raw()) => {
    const request = f.source.nextFrame(includeImage, f.current);
    f.emit(raw);
    return request;
  };
  f.assertIsolated = () => {
    assert.deepEqual(f.violations, [], 'No unexpected SDK calls or scoring/feed side effects');
    assert.deepEqual(scoring, beforeScoring, 'Source errors must not mutate scoring, settings or history');
    assert.deepEqual(f.feedEvents, [], 'The independent inspection feed must remain untouched');
    assert.deepEqual({ generation: f.feed.generation, sequence: f.feed.sequence, listener: f.feed.listener,
      includeImage: f.feed.includeImage, session: f.feed.session() }, beforeFeed);
  };
  f.assertReleased = () => {
    for (const resource of f.resources.filter(item => item.kind !== 'Image' || item.delivered)) {
      assert.equal(resource.released, true, resource.kind + '.' + resource.end + ' must eventually succeed');
    }
    assert.equal(f.clock.tasks.size, 0, 'No timer may survive disposal');
  };
  return f;
}

const releaseMethods = ['Session.release', 'PreviewOutput.release', 'CameraInput.close',
  'ImageReceiver.release', 'SkeletonDetector.destroy'];

test('actual source builds a continuous front PreviewOutput and ImageReceiver, never photos or AR', async () => {
  const f = setup();
  await f.prepare();
  assert.deepEqual(f.receiverOptions, { size: { width: 640, height: 480 }, capacity: 3 });
  assert.equal(f.calls.find(call => call.name === 'Session.addInput').args[0], f.input);
  assert.equal(f.calls.find(call => call.name === 'Session.addOutput').args[0], f.preview);
  assert.deepEqual(f.calls.find(call => call.name === 'PreviewOutput.enableBandwidthCompression').args, [false]);
  assert.deepEqual(f.calls.find(call => call.name === 'CameraInput.usePhysicalCameraOrientation').args, [true]);
  assert.equal(f.count('Session.start'), 1);
  assert.equal(f.receiver.handlers.size, 1);
  assert.match(f.source.statusDetail(), /640\D+480/);
  assert.equal(f.calls.some(call => /capture|PhotoOutput|ARSession|ImageSource/.test(call.name)), false);
});

test('Core Vision receives plain request data even when its runtime Request export is false', async () => {
  const f = setup({ profiles: [profile(128, 128)] });
  await f.prepare();
  for (const includeImage of [false, true]) {
    const frame = await f.frame(includeImage);
    const request = f.calls.filter(call => call.name === 'SkeletonDetector.process').at(-1).args[0];
    assert.deepEqual(Object.keys(request), ['inputData']);
    assert.deepEqual(Object.keys(request.inputData), ['pixelMap']);
    assert.equal(request.inputData.pixelMap, f.processed.at(-1).pixel);
    assert.equal(frame.sequence, includeImage ? 2 : 1);
    assert.equal(frame.points.length, 1);
    assert.equal(frame.imageError, false);
  }
  assert.equal(f.count('SkeletonDetector.process'), 2);
});

test('preparation is shared, idempotent, and reused for many sequential skeleton-only nextFrame calls', async () => {
  const f = setup({ profiles: [profile(128, 128)], physical: false, compression: false });
  const gate = f.block('SkeletonDetector.create');
  const first = f.source.prepare(f.current);
  const second = f.source.prepare(f.current);
  await flush();
  assert.equal(f.count('SkeletonDetector.create'), 1);
  gate.resolve();
  await completed(Promise.all([first, second]));
  for (let i = 1; i <= 24; i++) {
    const frame = await f.frame();
    assert.equal(frame.sequence, i);
    assert.equal(frame.imageUrl, '');
    assert.equal(frame.imageError, false);
    assert.equal(f.clock.tasks.size, 0);
  }
  await f.prepare();
  for (const name of ['camera.getCameraManager', 'image.createImageReceiver', 'CameraInput.open',
    'CameraManager.createPreviewOutput', 'Session.commitConfig', 'SkeletonDetector.create', 'Session.start']) assert.equal(f.count(name), 1, name);
  for (const name of ['CameraInput.usePhysicalCameraOrientation', 'PreviewOutput.enableBandwidthCompression',
    'image.createImagePacker', 'ImagePacker.packToData', 'Base64Helper.create']) assert.equal(f.count(name), 0, name);
  assert.equal(f.maxProcessing, 1);
});

const invalidProfiles = [[127, 128], [128, 127], [129, 128], [128, 129], [128.5, 256],
  [256, NaN], [Infinity, 128], [0, 480], [-128, 128], [1282, 128], [128, 1282],
  [1280, 722], [1024, 1024], [640, 480, 2000]];
test('front NV21 profile selection excludes invalid profiles and chooses the closest area with stable ties', async () => {
  const chosen = profile(640, 480);
  const f = setup({ profiles: [...invalidProfiles.map(args => profile(...args)), profile(1280, 720),
    profile(320, 240), chosen, profile(480, 640)] });
  await f.prepare();
  assert.equal(f.selected, chosen);
  const nearest = setup({ profiles: [profile(320, 240), profile(800, 600)] });
  await nearest.prepare();
  assert.equal(nearest.selected, nearest.config.profiles[1]);
});
for (const dimensions of [[128, 128], [1280, 720], [720, 1280], [960, 960]]) {
  test('accepts the advertised NV21 profile boundary ' + dimensions.join('x'), async () => {
    const f = setup({ profiles: [profile(...dimensions)] });
    await f.prepare();
    assert.equal(f.selected, f.config.profiles[0]);
  });
}
for (const dimensions of invalidProfiles) {
  test('rejects an unsupported preview profile ' + dimensions.join('x'), async () => {
    const f = setup({ profiles: [profile(...dimensions)] });
    await rejected(f.source.prepare(f.current), /no supported even-sized NV21 preview/);
    assert.equal(f.count('image.createImageReceiver'), 0);
  });
}

for (const [name, options, pattern] of [
  ['missing front camera', { device: undefined }, /No current default front camera/],
  ['back camera returned as front', { device: { cameraPosition: 1 } }, /No current default front camera/],
  ['unsupported scene', { scenes: [] }, /NORMAL_PHOTO/],
  ['missing receiver', { receiverAvailable: false }, /ImageReceiver is unavailable/],
  ['empty surface', { surface: '' }, /empty preview surface/],
  ['input rejected', { canAddInput: false }, /input cannot be added/],
  ['output rejected', { canAddOutput: false }, /preview cannot be added/],
  ['missing model', { detectorAvailable: false }, /detector could not be created/]
]) test('preparation fails safely for ' + name, async () => {
  const f = setup(options);
  await rejected(f.source.prepare(f.current), pattern);
  f.assertReleased();
});
for (const capability of ['SystemCapability.Multimedia.Camera.Core',
  'SystemCapability.Multimedia.Image.ImageReceiver', 'SystemCapability.AI.Vision.SkeletonDetection']) {
  test('requires capability ' + capability, async () => {
    const f = setup({ missingCapability: capability });
    await rejected(f.source.prepare(f.current), /capabilities are required/);
    assert.equal(f.count('camera.getCameraManager'), 0);
  });
}

test('unprepared and already-cancelled sources cannot acquire or process frames', async () => {
  const f = setup();
  await rejected(f.source.nextFrame(false, f.current), /Prepare the continuous skeleton preview/);
  f.allowed = false;
  await f.prepare();
  assert.equal(await completed(f.source.nextFrame(true, f.current)), undefined);
  assert.equal(f.calls.length, 0);
});

test('latest-image draining drops idle and busy frames without components, PixelMaps or encoding', async () => {
  const f = setup({ profiles: [profile(128, 128)] });
  await f.prepare();
  const idle = f.raw();
  f.emit(idle);
  await flush();
  assert.equal(idle.attempts, 1);
  assert.equal(f.count('Image.getComponent'), 0);
  assert.equal(f.count('image.createPixelMap'), 0);
  const gate = f.block('SkeletonDetector.process');
  const request = f.source.nextFrame(true, f.current);
  const old = f.raw();
  const latest = f.raw({ stride: 136 });
  f.emit(old, latest);
  await flush();
  assert.equal(old.delivered, undefined);
  assert.equal(latest.attempts, 1);
  assert.equal(f.calls.find(call => call.name === 'Image.getComponent').args[0], latest);
  await rejected(f.source.nextFrame(false, f.current), /Only one skeleton frame request/);
  const dropped = [];
  for (let i = 0; i < 8; i++) { const raw = f.raw(); dropped.push(raw); f.emit(raw); await flush(); }
  assert.ok(dropped.every(raw => raw.attempts === 1));
  assert.equal(f.count('Image.getComponent'), 1);
  assert.equal(f.count('image.createPixelMap'), 1);
  assert.equal(f.count('ImagePacker.packToData'), 0);
  assert.equal(f.count('Base64Helper.encodeToString'), 0);
  assert.equal(f.maxReading, 1);
  assert.equal(f.maxProcessing, 1);
  gate.resolve();
  assert.equal((await completed(request)).sequence, 1);
  assert.equal((await f.frame()).sequence, 2);
  assert.equal(f.count('image.createPixelMap'), 2);
  assert.equal(f.count('ImagePacker.packToData'), 1);
});

test('arrival bursts coalesce around a single pending latest-image read without queuing conversions', async () => {
  const f = setup({ profiles: [profile(128, 128)] });
  await f.prepare();
  const gate = f.block('ImageReceiver.readLatestImage');
  const request = f.source.nextFrame(false, f.current);
  f.emit(f.raw());
  await flush();
  const burst = Array.from({ length: 12 }, () => f.raw());
  burst.forEach(raw => f.emit(raw));
  await flush();
  assert.equal(f.count('ImageReceiver.readLatestImage'), 1);
  assert.equal(f.reading, 1);
  assert.equal(f.count('image.createPixelMap'), 0);
  gate.resolve();
  assert.equal((await completed(request)).sequence, 1);
  await flush();
  assert.equal(burst.at(-1).attempts, 1);
  assert.equal(f.maxReading, 1);
  assert.equal(f.count('ImageReceiver.readLatestImage'), 2);
  assert.equal(f.count('Image.getComponent'), 1);
  assert.equal(f.count('image.createPixelMap'), 1);
});

test('NV21 padded Y and VU rows are repacked without padding and survive native Image.release', async () => {
  const f = setup({ profiles: [profile(128, 256)] });
  await f.prepare();
  const raw = f.raw({ stride: 144 });
  const frame = await f.frame(false, raw);
  const conversion = f.calls.find(call => call.name === 'image.createPixelMap');
  assert.notEqual(conversion.args[0], raw.component.byteBuffer);
  assert.deepEqual(new Uint8Array(conversion.args[0]), raw.packed);
  assert.deepEqual(f.processed[0].pixel.bytes, raw.packed);
  assert.equal(conversion.args[0].byteLength, 128 * 256 * 3 / 2);
  assert.equal(raw.bytes[0], 238);
  assert.equal(frame.timestamp, f.clock.wall);
  assert.ok(f.calls.findIndex(call => call.name === 'Image.release') < f.calls.indexOf(conversion));
});
for (const [width, height, stride, trailingBytes] of [
  [640, 480, 640, 2048], [640, 480, 656, 4096], [128, 128, 128, 128], [128, 256, 144, 1]
]) test(`NV21 ignores trailing allocation bytes ${width}x${height}, stride=${stride}, tail=${trailingBytes}`, async () => {
  const f = setup({ profiles: [profile(width, height)], rotation: 270 });
  await f.prepare();
  for (const includeImage of [false, true]) {
    const raw = f.raw({ stride, trailingBytes });
    const frame = await f.frame(includeImage, raw);
    const conversion = f.calls.filter(call => call.name === 'image.createPixelMap').at(-1);
    assert.equal(raw.component.byteBuffer.byteLength, stride * height * 3 / 2 + trailingBytes);
    assert.equal(conversion.args[0].byteLength, width * height * 3 / 2);
    assert.notEqual(conversion.args[0], raw.component.byteBuffer);
    assert.deepEqual(new Uint8Array(conversion.args[0]), raw.packed);
    assert.deepEqual(f.processed.at(-1).pixel.bytes, raw.packed);
    assert.equal(raw.bytes.at(-1), 238);
    assert.deepEqual([frame.width, frame.height], [height, width]);
    assert.equal(frame.sequence, includeImage ? 2 : 1);
    assert.equal(frame.imageError, false);
    assert.equal(frame.imageUrl.startsWith('data:image/jpeg;base64,'), includeImage);
  }
  assert.equal(f.count('Session.start'), 1);
  assert.equal(f.count('ImagePacker.packToData'), 1);
});
for (const [name, corrupt] of [
  ['non-NV21 format', raw => { raw.format = 2000; }],
  ['wrong width', raw => { raw.size.width += 2; }],
  ['wrong height', raw => { raw.size.height += 2; }],
  ['short stride', raw => { raw.component.rowStride -= 2; }],
  ['odd stride', raw => { raw.component.rowStride++; }],
  ['fractional stride', raw => { raw.component.rowStride += .5; }],
  ['short bytes', raw => { raw.component.byteBuffer = new ArrayBuffer(raw.bytes.length - 1); }],
  ['missing bytes', raw => { raw.component.byteBuffer = undefined; }]
]) test('rejects invalid live frame ' + name + ' before conversion', async () => {
  const f = setup({ profiles: [profile(128, 128)] });
  await f.prepare();
  const raw = f.raw();
  corrupt(raw);
  await rejected(f.frame(false, raw), /Unsupported or invalid live preview frame/);
  assert.equal(raw.attempts, 1);
  assert.equal(f.count('image.createPixelMap'), 0);
  assert.equal(f.count('SkeletonDetector.process'), 0);
});

for (const displayRotation of [0, 1, 2, 3]) for (const cameraRotation of [0, 90, 180, 270]) {
  test(`rotation geometry display=${displayRotation * 90}, preview=${cameraRotation}`, async () => {
    const f = setup({ profiles: [profile(128, 256)], display: displayRotation, rotation: cameraRotation });
    await f.prepare();
    const frame = await f.frame();
    const angle = (cameraRotation + (displayRotation % 2 ? 180 : 0)) % 360;
    assert.equal(f.processed[0].rotation, angle);
    assert.deepEqual([frame.width, frame.height], angle % 180 ? [256, 128] : [128, 256]);
    assert.ok(f.calls.filter(call => call.name === 'PreviewOutput.getPreviewRotation')
      .every(call => call.args[0] === displayRotation * 90));
  });
}
test('rotation is refreshed for each captured frame without mirroring or restarting the stream', async () => {
  const f = setup({ profiles: [profile(128, 256)] });
  await f.prepare();
  f.config.display = 3;
  f.config.rotation = 90;
  const frame = await f.frame();
  assert.deepEqual([frame.width, frame.height], [256, 128]);
  assert.equal(f.processed[0].rotation, 270);
  assert.equal(f.count('Session.start'), 1);
  assert.equal(f.calls.some(call => /flip|mirror/i.test(call.name)), false);
});
for (const rotation of [undefined, NaN, Infinity, 45]) test('rejects invalid preview rotation ' + rotation, async () => {
  const f = setup({ rotation });
  await rejected(f.source.prepare(f.current), /invalid preview rotation/);
  assert.equal(f.count('SkeletonDetector.create'), 0);
});
for (const info of [{ size: { width: 128, height: 256 }, pixelFormat: RGBA },
  { size: { width: 256, height: 128 }, pixelFormat: NV21 }]) {
  test('validates actual post-rotation RGBA geometry ' + JSON.stringify(info), async () => {
    const f = setup({ profiles: [profile(128, 256)], rotation: 90, info });
    await f.prepare();
    await rejected(f.frame(), /expected RGBA geometry/);
    assert.equal(f.count('SkeletonDetector.process'), 0);
    assert.equal(f.count('PixelMap.release'), 1);
  });
}

test('JPEG and skeleton share the same rotated PixelMap and await asynchronous Base64 atomically', async () => {
  const f = setup({ profiles: [profile(128, 256)], rotation: 90,
    skeletons: pixel => [skeleton(.95, [point(5, pixel.size.width - 7, pixel.size.height - 9)])] });
  await f.prepare();
  const gate = f.block('Base64Helper.encodeToString');
  const timestamp = f.clock.wall;
  const state = tracked(f.frame(true));
  await flush();
  assert.equal(state.settled, false);
  assert.equal(f.packed[0].pixel, f.processed[0].pixel);
  assert.equal(f.processed[0].pixel.released, false);
  await f.clock.advance(120);
  gate.resolve();
  await flush();
  assert.equal(state.error, undefined);
  assert.equal(state.value.imageUrl, 'data:image/jpeg;base64,' + Buffer.from(f.packed[0].bytes).toString('base64'));
  assert.deepEqual(plain(state.value.points), [{ type: 5, x: 249, y: 119, confidence: .9 }]);
  assert.equal(state.value.timestamp, timestamp);
  assert.equal(f.count('ImagePacker.release'), 1);
  assert.equal(f.count('PixelMap.release'), 1);
});
for (const operation of ['image.createImagePacker', 'ImagePacker.packToData', 'Base64Helper.encodeToString']) {
  test('optional image failure preserves skeleton without poisoning the next frame: ' + operation, async () => {
    const f = setup({ profiles: [profile(128, 128)] });
    await f.prepare();
    f.failOnce(operation);
    const frame = await f.frame(true);
    assert.equal(frame.imageError, true);
    assert.equal(frame.imageUrl, '');
    assert.equal(frame.points.length, 1);
    assert.equal((await f.frame()).sequence, 2);
  });
}

test('people count includes every skeleton; highest valid score and visible-joint confidence break ties', async () => {
  const chosen = skeleton(.9, [point(5, 10, 20, .4), point(5, 30, 40, .9), point(6, 128, 128, .35),
    point(7, -1, 0), point(8, NaN, 0), point(9, 129, 1), point(10, 1, 129), point(11, 1, 1, .34),
    point(12, 1, 1, Infinity), point(13, 1, 1, 1.1), point(-1, 1, 1), point(17, 1, 1),
    point(1.5, 1, 1), { type: 0, point: null, score: 1 }]);
  const f = setup({ profiles: [profile(128, 128)], skeletons: [skeleton(.8, [point(0, 1, 1, 1)]),
    skeleton(.9, [point(5, 5, 5, .8)]), chosen, skeleton(NaN), skeleton(1.1)] });
  await f.prepare();
  const before = plain(f.config.skeletons);
  const frame = await f.frame();
  assert.equal(frame.people, 5);
  assert.deepEqual(plain(frame.points), [{ type: 5, x: 30, y: 40, confidence: .9 },
    { type: 6, x: 128, y: 128, confidence: .35 }]);
  frame.points[0].x = 999;
  assert.deepEqual(plain(f.config.skeletons), before);
  f.config.skeletons = [];
  const empty = await f.frame();
  assert.equal(empty.people, 0);
  assert.deepEqual(plain(empty.points), []);
  f.config.skeletons = [skeleton(-1, [point(0, 5, 6, .9)]), skeleton(Infinity, [point(0, 7, 8, .8)])];
  assert.equal((await f.frame()).points[0].x, 5);
  f.config.skeletons = [skeleton(.8), skeleton(.9, [])];
  assert.deepEqual(plain((await f.frame()).points), []);
});

const preparationStages = [
  ['ImageReceiver.getReceivingSurfaceId', 'CameraManager.createCameraInput'],
  ['CameraInput.open', 'CameraManager.createPreviewOutput'],
  ['Session.commitConfig', 'SkeletonDetector.create'],
  ['SkeletonDetector.create', 'Session.start'], ['Session.start', 'image.createPixelMap']
];
const frameStages = [
  ['ImageReceiver.readLatestImage', 'Image.getComponent'], ['Image.getComponent', 'image.createPixelMap'],
  ['image.createPixelMap', 'PixelMap.rotate'], ['PixelMap.rotate', 'SkeletonDetector.process'],
  ['SkeletonDetector.process', 'image.createImagePacker'], ['ImagePacker.packToData', 'Base64Helper.encodeToString'],
  ['Base64Helper.encodeToString', undefined]
];
for (const [stage, next] of preparationStages) for (const mode of ['predicate', 'dispose', 'rejection']) {
  test(`cancellation after ${stage} (${mode}) acquires nothing further and releases partial preparation`, async () => {
    const f = setup();
    const gate = f.block(stage);
    const preparing = tracked(f.source.prepare(f.current));
    await flush();
    assert.equal(f.count(stage), 1);
    let stopping;
    if (mode === 'dispose') stopping = tracked(f.source.dispose());
    else f.allowed = false;
    await flush();
    assert.equal(preparing.settled, false);
    if (stopping) assert.equal(stopping.settled, false, 'Disposal must wait for native preparation');
    if (mode === 'rejection') gate.reject(Error('cancelled native operation'));
    else gate.resolve();
    await flush();
    assert.equal(preparing.settled, true);
    assert.equal(preparing.error, undefined);
    assert.equal(f.count(next), 0);
    await completed(f.source.dispose());
    f.assertReleased();
  });
}
for (const [stage, next] of frameStages) for (const mode of ['predicate', 'dispose', 'rejection']) {
  test(`cancellation after ${stage} (${mode}) discards the frame and releases in-flight resources`, async () => {
    const f = setup({ profiles: [profile(128, 128)] });
    await f.prepare();
    const gate = f.block(stage);
    const result = tracked(f.frame(true));
    await flush();
    assert.equal(f.count(stage), 1);
    await rejected(f.source.nextFrame(true, f.current), /Only one skeleton frame request/);
    let stopping;
    if (mode === 'dispose') stopping = tracked(f.source.dispose());
    else f.allowed = false;
    await f.clock.advance(50);
    if (stopping) assert.equal(stopping.settled, false, 'Disposal must await native frame work');
    if (mode === 'rejection') gate.reject(Error('cancelled native operation'));
    else gate.resolve();
    await f.clock.advance(50);
    assert.equal(result.settled, true);
    assert.equal(result.error, undefined);
    assert.equal(result.value, undefined);
    if (next) assert.equal(f.count(next), 0);
    assert.equal(f.clock.tasks.size, 0);
    await completed(f.source.dispose());
    f.assertReleased();
  });
}

test('timeout uses the 5000ms budget, reports the last read error, and clears its polling timer', async () => {
  const f = setup();
  await f.prepare();
  f.failOnce('ImageReceiver.readLatestImage', 'mock buffer queue empty');
  const result = tracked(f.source.nextFrame(false, f.current));
  f.emit();
  await f.clock.advance(4999);
  assert.equal(result.settled, false);
  assert.equal(f.clock.tasks.size, 1);
  await f.clock.advance(1);
  assert.equal(result.settled, true);
  assert.match(String(result.error), /Timed out waiting.*mock buffer queue empty/);
  assert.equal(f.clock.tasks.size, 0);
  assert.equal(f.count('image.createPixelMap'), 0);
});
for (const jump of [-86400000, 86400000]) test('frame deadline is monotonic despite wall-clock jump ' + jump, async () => {
  const f = setup();
  await f.prepare();
  const result = tracked(f.source.nextFrame(false, f.current));
  await f.clock.advance(1000);
  f.clock.wall += jump;
  await f.clock.advance(50);
  assert.equal(result.settled, false, 'A wall-clock jump must not expire the monotonic frame budget early');
  await f.clock.advance(3950);
  assert.equal(result.settled, true, 'A wall-clock rollback must not extend the monotonic frame budget');
  assert.match(String(result.error), /Timed out waiting/);
  assert.equal(f.clock.tasks.size, 0);
});
for (const mode of ['predicate', 'dispose']) test('waiting-frame cancellation disposes its timer: ' + mode, async () => {
  const f = setup();
  await f.prepare();
  const result = tracked(f.source.nextFrame(false, f.current));
  await flush();
  assert.equal(f.clock.tasks.size, 1);
  if (mode === 'dispose') await completed(f.source.dispose());
  else { f.allowed = false; await f.clock.advance(50); }
  assert.equal(result.settled, true);
  assert.equal(result.error, undefined);
  assert.equal(result.value, undefined);
  assert.equal(f.clock.tasks.size, 0);
  const reads = f.count('ImageReceiver.readLatestImage');
  await f.clock.advance(10000);
  assert.equal(f.count('ImageReceiver.readLatestImage'), reads);
});

for (const target of ['input', 'preview', 'session', 'receiver']) test('source errors stay local and wake frame waiters: ' + target, async () => {
  const f = setup();
  await f.prepare();
  const result = f.source.nextFrame(false, f.current);
  f[target].handlers.get(target === 'receiver' ? 'imageArrival' : 'error')({ code: 77, message: 'injected camera failure' });
  await rejected(result, /77 injected camera failure/);
  await rejected(f.source.nextFrame(true, f.current), /77 injected camera failure/);
  assert.equal(f.count('image.createPixelMap'), 0);
  assert.equal(f.clock.tasks.size, 0);
});
for (const stage of ['SkeletonDetector.process', 'ImagePacker.packToData', 'Base64Helper.encodeToString']) {
  test('camera failure during ' + stage + ' cannot publish a late frame or mutate scoring/feed', async () => {
    const f = setup({ profiles: [profile(128, 128)] });
    await f.prepare();
    const gate = f.block(stage);
    const result = tracked(f.frame(true));
    await flush();
    f.preview.handlers.get('error')({ code: 78, message: 'late camera failure' });
    gate.resolve();
    await flush();
    assert.equal(result.settled, true);
    assert.match(String(result.error), /late camera failure/);
    assert.equal(result.value, undefined);
  });
}
for (const stage of ['CameraInput.open', 'Session.commitConfig', 'SkeletonDetector.create', 'Session.start',
  'image.createPixelMap', 'PixelMap.rotate', 'SkeletonDetector.process']) {
  test('native failure cleans all acquired resources without scoring/feed side effects: ' + stage, async () => {
    const f = setup({ profiles: [profile(128, 128)] });
    f.failOnce(stage);
    if (preparationStages.some(([name]) => name === stage)) await rejected(f.source.prepare(f.current), /failed/);
    else { await f.prepare(); await rejected(f.frame(true), /failed/); }
    await completed(f.source.dispose());
    f.assertReleased();
  });
}

test('successful disposal is shared and idempotent; no successful resource is released twice', async () => {
  const f = setup({ profiles: [profile(128, 128)] });
  await f.prepare();
  await f.frame(true);
  const gate = f.block('Session.stop');
  const first = f.source.dispose();
  assert.equal(f.source.dispose(), first);
  const result = tracked(first);
  await flush();
  assert.equal(result.settled, false);
  gate.resolve();
  await completed(first);
  await completed(f.source.dispose());
  for (const name of [...releaseMethods, 'Session.stop', 'Session.off', 'PreviewOutput.off', 'CameraInput.off',
    'ImageReceiver.off', 'Image.release', 'PixelMap.release', 'ImagePacker.release']) assert.equal(f.count(name), 1, name);
  assert.equal(await completed(f.source.nextFrame(true, f.current)), undefined);
  await f.prepare();
  assert.equal(f.count('Session.start'), 1);
  f.assertReleased();
});

test('disposal attempts every remaining resource even when off, stop and all releases throw', async () => {
  const f = setup();
  await f.prepare();
  const operations = ['ImageReceiver.off', 'Session.stop', 'Session.off', 'Session.release', 'PreviewOutput.off',
    'PreviewOutput.release', 'CameraInput.off', 'CameraInput.close', 'ImageReceiver.release', 'SkeletonDetector.destroy'];
  operations.forEach(name => f.failOnce(name));
  const error = await rejected(f.source.dispose(), /ImageReceiver\.off/);
  for (const name of operations) {
    assert.equal(f.count(name), 1, name + ' must be attempted despite earlier cleanup failures');
    assert.ok(String(error).includes(name), 'Cleanup error must identify ' + name);
  }
  assert.equal(f.clock.tasks.size, 0);
  await completed(f.source.dispose());
  for (const name of releaseMethods) assert.equal(f.count(name), 2, 'Retry must recover ' + name);
  assert.equal(f.count('Session.stop'), 2);
  const attempts = f.resources.map(resource => resource.attempts);
  await completed(f.source.dispose());
  assert.deepEqual(f.resources.map(resource => resource.attempts), attempts);
  f.assertReleased();
});

test('a rejected dispose promise is not cached forever and concurrent retries share a new task', async () => {
  const f = setup();
  await f.prepare();
  f.failOnce('Session.release');
  const first = f.source.dispose();
  await rejected(first, /Session.release/);
  const gate = f.block('Session.release');
  const retry = f.source.dispose();
  const result = tracked(retry);
  await flush();
  assert.notEqual(retry, first, 'Reset the cached rejected dispose promise before retrying');
  assert.equal(f.source.dispose(), retry, 'Concurrent cleanup retries must share the new task');
  assert.equal(result.settled, false);
  gate.resolve();
  await completed(retry);
  f.assertReleased();
});
for (const operation of releaseMethods) test('failed cleanup is retained and retried, without repeating successful releases: ' + operation, async () => {
  const f = setup();
  await f.prepare();
  f.failOnce(operation);
  await rejected(f.source.dispose(), new RegExp(operation.replaceAll('.', '\\.')));
  for (const name of releaseMethods) assert.equal(f.count(name), 1, 'First disposal must attempt ' + name);
  const retry = tracked(f.source.dispose());
  await flush();
  assert.equal(f.count(operation), 2, operation + ' must retain its failed resource for a real retry');
  assert.equal(retry.settled, true);
  assert.equal(retry.error, undefined, 'Historical release errors must not poison successful retry');
  for (const name of releaseMethods.filter(name => name !== operation)) assert.equal(f.count(name), 1, name + ' must not repeat');
  await completed(f.source.dispose());
  assert.equal(f.count(operation), 2);
  for (const name of releaseMethods) assert.equal(f.source.statusDetail().includes(name), false);
  f.assertReleased();
});
for (const operation of ['Image.release', 'ImagePacker.release', 'PixelMap.release']) {
  test('failed frame-local resource release remains owned until disposal retry succeeds: ' + operation, async () => {
    const f = setup({ profiles: [profile(128, 128)] });
    await f.prepare();
    f.failOnce(operation);
    f.failOnce(operation);
    await rejected(f.frame(true), /release/);
    await rejected(f.source.dispose(), /release/);
    assert.equal(f.count(operation), 2, 'First disposal must retry the failed ' + operation + ' resource');
    await completed(f.source.dispose());
    assert.equal(f.count(operation), 3, 'Failed temporary resources must survive a rejected dispose for retry');
    await completed(f.source.dispose());
    assert.equal(f.count(operation), 3, 'Successful temporary resource releases must not repeat');
    for (const name of releaseMethods) assert.equal(f.count(name), 1, name);
    f.assertReleased();
  });
}

test('real controller remains cleanup-blocked after source rejection and unlocks only after a successful source retry', async () => {
  const f = setup();
  const { LiveSkeletonController } = f.load('services/LiveSkeletonController');
  f.controller = new LiveSkeletonController();
  let state;
  f.controller.observe(value => { state = value; });
  f.controller.start(f.source, async () => true, f.current);
  await flush();
  assert.equal(state.phase, 'running');
  f.failOnce('CameraInput.close');
  const stopping = f.controller.stop();
  await f.clock.advance(50);
  await completed(stopping);
  assert.equal(state.cleanupBlocked, true);
  assert.equal(f.controller.isBusy(), true);
  assert.equal(state.frame, undefined);
  assert.equal(f.clock.tasks.size, 0);
  await completed(f.controller.stop());
  assert.equal(f.count('CameraInput.close'), 2, 'Controller retry must actually retry the retained camera input');
  assert.equal(state.cleanupBlocked, false);
  assert.equal(f.controller.isBusy(), false);
  assert.equal(state.phase, 'idle');
});

async function main() {
  let passes = 0;
  const failures = [];
  for (const item of tests) {
    fixtures = [];
    let failure;
    let watchdog;
    try {
      await Promise.race([item.run(), new Promise((resolve, reject) => {
        watchdog = setImmediate(() => reject(Error('Test stalled without a resolvable mock operation')));
      })]);
    } catch (error) { failure = error; }
    finally { clearImmediate(watchdog); }
    for (const f of fixtures) {
      try {
        f.allowed = false;
        f.allGates.forEach(gate => gate.resolve());
        await flush();
        if (f.controller) {
          const stopping = f.controller.stop();
          await f.clock.advance(50);
          await completed(stopping);
        }
        try { await completed(f.source.dispose()); f.assertReleased(); }
        catch (error) { if (!failure) throw error; }
        assert.equal(f.clock.tasks.size, 0, 'Fixture leaked a timer');
        f.assertIsolated();
      } catch (error) { failure ??= error; }
    }
    if (failure) {
      failures.push(item.name);
      console.error('FAIL: ' + item.name + '\n' + (failure.stack ?? failure));
    } else { passes++; console.log('PASS: ' + item.name); }
  }
  console.log(`\nLive skeleton camera: ${passes} passed, ${failures.length} failed, ${tests.length} total`);
  if (failures.length) {
    console.error('Defects remain in the actual ArkTS source; no source was rewritten or substituted.');
    process.exitCode = 1;
  }
}
main().catch(error => { console.error(error); process.exitCode = 1; });
