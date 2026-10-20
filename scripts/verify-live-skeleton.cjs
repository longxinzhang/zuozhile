#!/usr/bin/env node
const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const { execFileSync } = require('node:child_process');
const { typescript: ts } = require('./deveco-sdk.cjs');
const root = path.resolve(__dirname, '..');
const sourceRoot = 'entry/src/main/ets/';
const baseline = process.argv[2] || 'bf87b4125803885547b17e97febe321c55dd081e';
const compilerOptions = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS };
const texts = new Map();
const trees = new Map();
const tests = [];
let resources;
const normalize = value => JSON.parse(JSON.stringify(value));
const test = (name, run) => tests.push({ name, run });
const near = (actual, expected, tolerance = 1e-8) =>
  assert.ok(Math.abs(actual - expected) <= tolerance, `${actual} != ${expected}`);
const flush = async () => { for (let i = 0; i < 40; i++) await Promise.resolve(); };

function read(file) {
  assert.notEqual(file, 'services/LiveSkeletonCameraSource', 'Camera implementation is outside this verifier');
  if (!texts.has(file)) texts.set(file, fs.readFileSync(path.join(root, sourceRoot + file + '.ets'), 'utf8'));
  return texts.get(file);
}

function tree(file) {
  if (!trees.has(file)) trees.set(file, ts.createSourceFile(file + '.ts',
    read(file).replace(/\bstruct\s+/g, 'class '), ts.ScriptTarget.Latest, true));
  return trees.get(file);
}

function component(file, name) {
  const node = tree(file).statements.find(item => ts.isClassDeclaration(item) && item.name?.text === name);
  assert.ok(node, `Missing component ${file}:${name}`);
  return node;
}

function member(file, name, key) {
  const node = component(file, name).members.find(item => item.name?.getText(tree(file)) === key);
  assert.ok(node, `Missing member ${file}:${name}.${key}`);
  return node;
}

function descendants(node, predicate) {
  const result = [];
  function visit(child) {
    if (predicate(child)) result.push(child);
    ts.forEachChild(child, visit);
  }
  visit(node);
  return result;
}

function calls(node, name) {
  return descendants(node, item => ts.isCallExpression(item) &&
    (ts.isPropertyAccessExpression(item.expression) ? item.expression.name.text : item.expression.getText()) === name);
}

function evaluate(text, subject, dependencies = {}) {
  return vm.runInNewContext(ts.transpileModule(`(function () { return (${text}); }).call(subject);`,
    { compilerOptions }).outputText, { subject, Error, ...dependencies });
}

function methodClass(file, name, names, dependencies = {}) {
  const body = names.map(key => member(file, name, key).getText(tree(file))).join('\n');
  return vm.runInNewContext(ts.transpileModule(`class Subject { ${body} } Subject;`,
    { compilerOptions }).outputText, { Error, ...dependencies });
}

function controlArgument(file, name, id, attribute, method = 'build') {
  const ast = tree(file);
  const matches = calls(member(file, name, method), 'id').filter(node => node.arguments[0]?.text === id);
  assert.equal(matches.length, 1, `Expected one control ${id}`);
  let chain = matches[0];
  while (ts.isPropertyAccessExpression(chain.parent) && chain.parent.expression === chain &&
    ts.isCallExpression(chain.parent.parent)) chain = chain.parent.parent;
  const argumentsForAttribute = calls(chain, attribute);
  assert.equal(argumentsForAttribute.length, 1, `Expected ${id}.${attribute}`);
  return argumentsForAttribute[0].arguments[0].getText(ast);
}

function deferred(value) {
  let resolve;
  let reject;
  const promise = new Promise((yes, no) => { resolve = yes; reject = no; });
  const result = { promise, resolve, reject, value };
  resources?.gates.push(result);
  return result;
}

function tracked(promise) {
  const state = { settled: false, value: undefined, error: undefined };
  Promise.resolve(promise).then(value => { state.settled = true; state.value = value; },
    error => { state.settled = true; state.error = error; });
  return state;
}

async function completed(promise, message = 'Operation must settle without a real timer') {
  const state = tracked(promise);
  await flush();
  assert.equal(state.settled, true, message);
  if (state.error) throw state.error;
  return state.value;
}

class Clock {
  constructor() {
    this.time = 10000;
    this.wall = Date.UTC(2026, 9, 19, 9);
    this.tasks = new Map();
    this.history = [];
    this.errors = [];
    this.nextId = 0;
    this.maxTimeouts = 0;
    this.maxIntervals = 0;
    this.uptimeReads = 0;
  }

  add(callback, delay, interval) {
    assert.equal(typeof callback, 'function');
    assert.ok(Number.isFinite(delay) && delay >= 0, 'Timer delay must be finite and nonnegative');
    const id = ++this.nextId;
    const task = { id, callback, delay, interval, due: this.time + delay };
    this.tasks.set(id, task);
    this.history.push({ id, delay, interval, at: this.time });
    this.maxTimeouts = Math.max(this.maxTimeouts, this.pending(false).length);
    this.maxIntervals = Math.max(this.maxIntervals, this.pending(true).length);
    return id;
  }

  pending(interval) {
    return [...this.tasks.values()].filter(task => task.interval === interval);
  }

  globals() {
    const clock = this;
    return {
      Date: class extends Date { static now() { return clock.wall; } },
      setTimeout: (callback, delay) => this.add(callback, delay, false),
      clearTimeout: id => this.tasks.delete(id),
      setInterval: (callback, delay) => this.add(callback, delay, true),
      clearInterval: id => this.tasks.delete(id)
    };
  }

  async advance(elapsed) {
    assert.ok(elapsed >= 0);
    const target = this.time + elapsed;
    await flush();
    let steps = 0;
    while (true) {
      const next = [...this.tasks.values()].filter(task => task.due <= target)
        .sort((a, b) => a.due - b.due || a.id - b.id)[0];
      if (!next) break;
      assert.ok(++steps < 10000, 'Timer loop did not yield under backpressure');
      this.time = next.due;
      if (next.interval) next.due += Math.max(1, next.delay);
      else this.tasks.delete(next.id);
      try {
        const result = next.callback();
        if (result?.then) result.catch(error => this.errors.push(error));
      } catch (error) {
        this.errors.push(error);
      }
      await flush();
    }
    this.time = target;
    await flush();
    if (this.errors.length) throw this.errors[0];
  }
}

function load(file, clock = new Clock(), cache = new Map()) {
  assert.ok(['models/LiveSkeletonMonitor', 'services/LiveSkeletonController', 'models/PostureTypes'].includes(file),
    'Unexpected module load: ' + file);
  if (cache.has(file)) return cache.get(file).exports;
  const module = { exports: {} };
  cache.set(file, module);
  vm.runInNewContext(ts.transpileModule(read(file), { compilerOptions }).outputText, {
    module, exports: module.exports, Error, Promise, ...clock.globals(), require(name) {
      if (name === '@kit.BasicServicesKit') return { systemDateTime: {
        TimeType: { STARTUP: 73 }, getUptime(type, nanoseconds) {
          assert.equal(type, 73, 'Use startup monotonic time, not wall time');
          assert.equal(nanoseconds, false, 'Uptime must be milliseconds');
          clock.uptimeReads++;
          return clock.time;
        }
      } };
      assert.ok(name.startsWith('.'), 'Unexpected native dependency: ' + name);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)), clock, cache);
    }
  }, { filename: sourceRoot + file + '.ets' });
  return module.exports;
}

function frame(clock, sequence = 1, includeImage = false) {
  return { sequence, timestamp: clock.wall, width: 720, height: 1280, people: 1,
    points: [{ type: 0, x: 360, y: 120, confidence: .98 },
      { type: 5, x: 160, y: 320, confidence: .95 }, { type: 6, x: 560, y: 320, confidence: .96 }],
    imageUrl: includeImage ? 'data:image/jpeg;base64,AQID' : '', imageError: false };
}

function fakeSource(clock, plan = {}) {
  const data = { prepares: 0, frames: [], disposes: 0, preparing: false, inFlight: 0, maximum: 0, order: [] };
  const source = {
    async prepare(isCurrent) {
      assert.equal(typeof isCurrent, 'function');
      data.prepares++;
      data.order.push('prepare');
      data.preparing = true;
      data.prepareCurrent = isCurrent;
      try { await plan.prepare?.(isCurrent); } finally { data.preparing = false; }
    },
    async nextFrame(includeImage, isCurrent) {
      assert.equal(typeof includeImage, 'boolean');
      assert.equal(typeof isCurrent, 'function');
      const capture = { includeImage, isCurrent, at: clock.time };
      data.frames.push(capture);
      data.order.push('frame');
      data.inFlight++;
      data.maximum = Math.max(data.maximum, data.inFlight);
      try {
        return plan.next ? await plan.next(includeImage, isCurrent, data.frames.length) :
          frame(clock, data.frames.length, includeImage);
      } finally { data.inFlight--; }
    },
    async dispose() {
      data.disposes++;
      data.order.push('dispose');
      assert.equal(data.inFlight, 0, 'Do not dispose while a frame or encoding is still in flight');
      assert.equal(data.preparing, false, 'Do not dispose while preparation is still in flight');
      await plan.dispose?.();
    },
    statusDetail() { return 'Fake live source ready'; }
  };
  return { source, data };
}

function setup(plan = {}) {
  const clock = new Clock();
  const { LiveSkeletonController } = load('services/LiveSkeletonController', clock);
  const controller = new LiveSkeletonController();
  const f = { clock, controller, ...fakeSource(clock, plan), states: [], allowed: true, accesses: 0 };
  controller.observe(state => { f.state = state; f.states.push(state); });
  f.start = (access = async () => true, source = f.source) => controller.start(source,
    async () => { f.accesses++; return access(); }, () => f.allowed);
  resources?.fixtures.push(f);
  return f;
}

function queuedFrames() {
  const gates = [];
  const f = setup({ next: () => { const gate = deferred(); gates.push(gate); return gate.promise; } });
  f.gates = gates;
  return f;
}

async function stop(f) {
  await completed(f.controller.stop(), 'Stop must finish once its source has finished');
  assert.equal(f.controller.isBusy(), false);
  assert.equal(f.clock.tasks.size, 0, 'No timers may survive stop');
}

test('model defaults and explicit fake source match the public monitor contract', () => {
  const model = load('models/LiveSkeletonMonitor');
  const state = new model.LiveSkeletonState();
  assert.equal(state.phase, model.LiveSkeletonPhase.IDLE);
  assert.equal(state.frame, undefined);
  for (const key of ['frames', 'fps', 'processingMs', 'frameAgeMs']) assert.equal(state[key], 0);
  assert.deepEqual(Object.values(model.LiveSkeletonPhase).sort(), ['error', 'idle', 'preparing', 'running', 'stopping']);
  const contract = tree('models/LiveSkeletonMonitor').statements.find(node =>
    ts.isInterfaceDeclaration(node) && node.name.text === 'LiveSkeletonFrameSource');
  assert.ok(contract);
  const source = fakeSource(new Clock()).source;
  assert.deepEqual(contract.members.map(node => node.name.text).sort(), Object.keys(source).sort());
  for (const key of Object.keys(source)) assert.equal(typeof source[key], 'function');
});

test('start is gated by canRun and rejects duplicate active sessions', async () => {
  const f = setup();
  f.allowed = false;
  f.start();
  await flush();
  assert.equal(f.accesses, 0);
  assert.equal(f.data.prepares, 0);
  assert.equal(f.controller.isBusy(), false);
  f.allowed = true;
  f.start();
  assert.equal(f.controller.isBusy(), true);
  assert.equal(f.state.phase, 'preparing');
  f.start();
  await flush();
  f.start();
  assert.equal(f.accesses, 1);
  assert.equal(f.data.prepares, 1);
  await stop(f);
  assert.equal(f.data.disposes, 1);
});

test('one prepare serves many skeleton-only frames at the 100ms target without timer queues', async () => {
  const f = setup();
  f.start();
  await flush();
  await f.clock.advance(2400);
  assert.equal(f.data.prepares, 1);
  assert.equal(f.data.frames.length, 25);
  assert.equal(f.state.frames, 25);
  assert.equal(f.data.maximum, 1);
  f.data.frames.forEach((capture, i) => {
    assert.equal(capture.at, 10000 + i * 100);
    assert.equal(capture.includeImage, false, 'Default mode must not request images or encoding');
  });
  assert.equal(f.state.frame.imageUrl, '');
  assert.equal(f.clock.maxTimeouts, 1, 'Only one continuation timeout may exist');
  assert.equal(f.clock.maxIntervals, 1, 'Status must not create one timer per frame');
  assert.ok(f.clock.uptimeReads > 0);
  await stop(f);
});

test('100ms pacing subtracts processing time instead of adding it to every frame', async () => {
  const f = queuedFrames();
  f.start();
  await flush();
  await f.clock.advance(40);
  f.gates[0].resolve(frame(f.clock));
  await flush();
  assert.equal(f.state.processingMs, 40);
  assert.equal(f.clock.pending(false).length, 1);
  assert.equal(f.clock.pending(false)[0].due, 10100);
  await f.clock.advance(59);
  assert.equal(f.data.frames.length, 1);
  await f.clock.advance(1);
  assert.equal(f.data.frames.length, 2);
  await f.clock.advance(30);
  f.gates[1].resolve(frame(f.clock, 2));
  await flush();
  assert.equal(f.clock.pending(false)[0].due, 10200);
  await stop(f);
});

test('slow capture applies backpressure with one in-flight frame and no queued catch-up', async () => {
  const f = queuedFrames();
  f.start();
  await flush();
  await f.clock.advance(760);
  assert.equal(f.data.frames.length, 1);
  assert.equal(f.data.inFlight, 1);
  assert.equal(f.clock.pending(false).length, 0, 'Never schedule another capture while awaiting a frame');
  assert.equal(f.clock.pending(true).length, 1);
  f.gates[0].resolve(frame(f.clock));
  await flush();
  assert.equal(f.state.processingMs, 760);
  const continuation = f.clock.pending(false);
  assert.equal(continuation.length, 1);
  assert.ok(continuation[0].due >= f.clock.time && continuation[0].due <= f.clock.time + 100);
  await f.clock.advance(1000);
  assert.equal(f.data.frames.length, 2, 'Backpressure must not enqueue all missed 100ms ticks');
  assert.equal(f.data.maximum, 1);
  const stopping = tracked(f.controller.stop());
  f.gates[1].resolve(frame(f.clock, 2));
  await flush();
  assert.equal(stopping.settled, true);
  assert.equal(f.clock.tasks.size, 0);
});

test('FPS and processing time are measured from monotonic completions, not the 10 FPS target', async () => {
  const f = queuedFrames();
  f.start();
  await flush();
  const completions = [];
  for (let i = 0; i < 4; i++) {
    await f.clock.advance(320);
    f.clock.wall += i % 2 ? -86400000 : 864000000;
    completions.push(f.clock.time);
    f.gates[i].resolve(frame(f.clock, i + 1));
    await flush();
    assert.equal(f.state.processingMs, 320);
    if (i === 0) assert.equal(f.state.fps, 0, 'A single completion cannot establish an FPS rate');
    if (i < 3) {
      const wait = f.clock.pending(false)[0];
      assert.ok(wait);
      await f.clock.advance(wait.due - f.clock.time);
    }
  }
  near(f.state.fps, 3000 / (completions[3] - completions[0]));
  assert.ok(f.state.fps > 0 && f.state.fps < 4);
  assert.equal(f.state.frames, 4);
  await stop(f);
});

test('stalled frames clear after two seconds and FPS decays without trusting wall timestamps', async () => {
  const f = queuedFrames();
  f.start();
  await flush();
  const first = frame(f.clock);
  first.timestamp += 864000000;
  f.gates[0].resolve(first);
  await flush();
  await f.clock.advance(2000);
  assert.deepEqual(normalize(f.state.frame), normalize(first), 'Exactly two seconds is not older than two seconds');
  f.clock.wall -= 864000000;
  await f.clock.advance(250);
  assert.equal(f.state.frame, undefined, 'Old image and points must disappear during a stalled capture');
  assert.ok(f.state.frameAgeMs > 2000);
  assert.equal(f.state.fps, 0);
  assert.equal(f.state.phase, 'running');
  assert.equal(f.data.frames.length, 2);
  const stopping = f.controller.stop();
  f.gates[1].resolve(frame(f.clock, 2));
  await completed(stopping);
});

test('image revisions discard old frames and switching images off clears the visible frame immediately', async () => {
  const f = queuedFrames();
  f.start();
  await flush();
  f.controller.setIncludeImage(true);
  f.gates[0].resolve(frame(f.clock));
  await flush();
  assert.equal(f.state.frames, 0, 'An old skeleton-only request cannot publish after an image-mode revision');
  await f.clock.advance(100);
  assert.equal(f.data.frames[1].includeImage, true);
  f.gates[1].resolve(frame(f.clock, 2, true));
  await flush();
  assert.ok(f.state.frame.imageUrl);
  await f.clock.advance(100);
  assert.equal(f.data.frames[2].includeImage, true);
  f.controller.setIncludeImage(false);
  assert.equal(f.state.frame, undefined, 'Privacy must clear synchronously, not after encoding finishes');
  assert.equal(f.state.frameAgeMs, 0);
  f.gates[2].resolve(frame(f.clock, 3, true));
  await flush();
  assert.equal(f.state.frame, undefined);
  assert.equal(f.state.frames, 1, 'Discarded image revisions must not count as displayed frames');
  await f.clock.advance(100);
  assert.equal(f.data.frames[3].includeImage, false);
  f.gates[3].resolve(frame(f.clock, 4));
  await flush();
  assert.equal(f.state.frame.imageUrl, '');
  assert.equal(f.state.frame.sequence, 4);
  await stop(f);
});

test('image revision uses a generation, including an on/off/on round trip during encoding', async () => {
  const f = queuedFrames();
  f.controller.setIncludeImage(true);
  f.start();
  await flush();
  f.controller.setIncludeImage(false);
  f.controller.setIncludeImage(true);
  f.gates[0].resolve(frame(f.clock, 1, true));
  await flush();
  assert.equal(f.state.frame, undefined);
  assert.equal(f.state.frames, 0);
  await f.clock.advance(100);
  f.controller.setIncludeImage(true);
  f.gates[1].resolve(frame(f.clock, 2, true));
  await flush();
  assert.equal(f.state.frame.sequence, 2, 'An idempotent mode setter must not invalidate its own current frame');
  await stop(f);
});

for (const phase of ['access', 'prepare', 'capture', 'encoding']) {
  test(`stop during ${phase} waits for completion and disposal; duplicate stop is safe and restart stays blocked`, async () => {
    const pending = deferred(true);
    const captured = deferred();
    const disposal = deferred();
    let stage = '';
    let f;
    f = setup({
      prepare: async () => { if (phase === 'prepare') await pending.promise; },
      next: async image => {
        if (phase === 'encoding') { stage = 'capture'; await captured.promise; stage = 'encoding'; }
        if (phase === 'capture' || phase === 'encoding') await pending.promise;
        return frame(f.clock, 1, image);
      },
      dispose: () => disposal.promise
    });
    if (phase === 'encoding') f.controller.setIncludeImage(true);
    f.start(phase === 'access' ? () => pending.promise : async () => true);
    await flush();
    if (phase === 'encoding') {
      assert.equal(stage, 'capture');
      captured.resolve();
      await flush();
      assert.equal(stage, 'encoding');
      assert.equal(f.data.frames[0].includeImage, true);
    }
    const firstStop = tracked(f.controller.stop());
    const secondStop = tracked(f.controller.stop());
    const before = f.states.length;
    assert.equal(f.state.phase, 'stopping');
    assert.equal(f.controller.isBusy(), true);
    assert.equal(f.state.frame, undefined);
    assert.equal(f.state.fps, 0);
    assert.equal(f.clock.tasks.size, 0);
    const replacement = fakeSource(f.clock);
    f.start(async () => true, replacement.source);
    await f.clock.advance(1000);
    assert.equal(firstStop.settled, false);
    assert.equal(secondStop.settled, false);
    assert.equal(f.data.disposes, 0, 'Release must wait for the asynchronous source operation');
    assert.equal(replacement.data.prepares, 0);
    assert.equal(f.accesses, 1);
    pending.resolve(true);
    await flush();
    assert.equal(f.data.disposes, 1);
    assert.equal(f.controller.isBusy(), true, 'Busy must cover the entire delayed disposal');
    assert.equal(firstStop.settled, false);
    f.controller.stop();
    f.start(async () => true, replacement.source);
    await flush();
    assert.equal(replacement.data.prepares, 0);
    assert.equal(f.data.disposes, 1);
    assert.ok(f.states.slice(before).every(state => !state.frame && state.frames === 0), 'Discard late frames');
    if (phase === 'access') assert.equal(f.data.prepares, 0);
    if (phase === 'prepare') assert.equal(f.data.frames.length, 0);
    disposal.resolve();
    await flush();
    assert.equal(firstStop.settled, true);
    assert.equal(secondStop.settled, true);
    assert.equal(firstStop.error, undefined);
    assert.equal(f.state.phase, 'idle');
    assert.equal(f.controller.isBusy(), false);
    assert.equal(f.clock.tasks.size, 0);
    f.start(async () => true, replacement.source);
    await flush();
    assert.equal(replacement.data.prepares, 1, 'A completed stop must allow a new session');
    assert.equal(f.state.phase, 'running');
    await stop(f);
    assert.equal(replacement.data.disposes, 1);
    assert.equal(f.data.disposes, 1);
  });
}

test('stop wakes a pending pacing delay and removes status and continuation timers', async () => {
  const f = setup();
  f.start();
  await flush();
  assert.equal(f.clock.tasks.size, 2);
  await stop(f);
  const count = f.data.frames.length;
  await f.clock.advance(10000);
  assert.equal(f.data.frames.length, count);
  assert.equal(f.state.frame, undefined);
  await stop(f);
  assert.equal(f.data.disposes, 1);
});

for (const phase of ['access', 'prepare', 'capture']) {
  test(`canRun becoming false during ${phase} cancels without late publication or automatic restart`, async () => {
    const gate = deferred(true);
    const f = setup({ prepare: () => phase === 'prepare' ? gate.promise : undefined,
      next: () => gate.promise });
    f.start(phase === 'access' ? () => gate.promise : async () => true);
    await flush();
    f.allowed = false;
    await f.clock.advance(250);
    if (phase === 'capture') {
      assert.equal(f.state.phase, 'stopping');
      assert.equal(f.data.frames[0].isCurrent(), false);
    }
    if (phase === 'prepare') assert.equal(f.data.prepareCurrent(), false);
    gate.resolve(frame(f.clock));
    await flush();
    assert.equal(f.state.phase, 'idle');
    assert.equal(f.controller.isBusy(), false);
    assert.equal(f.state.frame, undefined);
    assert.equal(f.state.frames, 0);
    assert.equal(f.data.disposes, 1);
    assert.equal(f.clock.tasks.size, 0);
    if (phase === 'access') assert.equal(f.data.prepares, 0);
    if (phase === 'prepare') assert.equal(f.data.frames.length, 0);
    f.allowed = true;
    await f.clock.advance(1000);
    assert.equal(f.accesses, 1);
  });
}

for (const failure of ['denied', 'access', 'prepare', 'nextFrame', 'dispose', 'nextFrame+dispose']) {
  test(`${failure} failure cleans the source once and publishes a terminal error without leaked timers`, async () => {
    const disposal = deferred();
    const f = setup({
      prepare: () => { if (failure === 'prepare') throw Error('prepare failed'); },
      next: () => { if (failure.startsWith('nextFrame')) throw Error('nextFrame failed'); return undefined; },
      dispose: async () => { await disposal.promise; if (failure.includes('dispose')) throw Error('dispose failed'); }
    });
    f.start(async () => { if (failure === 'access') throw Error('access failed'); return failure !== 'denied'; });
    await flush();
    if (failure === 'dispose') f.controller.stop();
    await flush();
    assert.equal(f.state.phase, 'stopping');
    assert.equal(f.controller.isBusy(), true);
    assert.equal(f.data.disposes, 1);
    const stopping = tracked(f.controller.stop());
    assert.equal(stopping.settled, false);
    disposal.resolve();
    await flush();
    assert.equal(stopping.settled, true);
    assert.equal(stopping.error, undefined, 'Errors belong in state, not unhandled operation rejections');
    assert.equal(f.state.phase, 'error');
    assert.ok(f.state.detail.length > 0);
    if (failure === 'access' || failure === 'prepare' || failure.startsWith('nextFrame')) {
      assert.ok(f.state.detail.includes(failure.split('+')[0]), 'Preserve the original source failure');
    }
    assert.equal(f.state.frame, undefined);
    assert.equal(f.state.fps, 0);
    assert.equal(f.controller.isBusy(), failure.includes('dispose'));
    assert.equal(f.state.cleanupBlocked, failure.includes('dispose'));
    assert.equal(f.clock.tasks.size, 0);
    if (failure.includes('dispose')) {
      const before = f.accesses;
      f.start();
      await flush();
      assert.equal(f.accesses, before, 'Unconfirmed cleanup must keep the camera locked');
    } else {
      await stop(f);
      assert.equal(f.data.disposes, 1);
    }
  });
}

test('snapshots are independent outer objects and cannot mutate controller-owned state', async () => {
  const f = setup();
  const idle = f.state;
  const original = normalize(idle);
  f.start();
  await flush();
  const running = f.state;
  const originalFrame = running.frame;
  assert.notEqual(idle, running);
  assert.deepEqual(normalize(idle), original, 'Retained snapshots must not change on later transitions');
  Object.assign(running, { phase: 'corrupted', frame: undefined, frames: 999, fps: 999, detail: 'corrupted' });
  let fresh;
  f.controller.observe(state => { fresh = state; });
  assert.equal(fresh.phase, 'running');
  assert.equal(fresh.frames, 1);
  assert.notEqual(fresh.frame, originalFrame);
  assert.deepEqual(normalize(fresh.frame), normalize(originalFrame));
  assert.notEqual(fresh.detail, 'corrupted');
  const retained = fresh;
  const saved = normalize(retained);
  await f.clock.advance(100);
  assert.notEqual(fresh, retained);
  assert.deepEqual(normalize(retained), saved);
  assert.equal(new Set(f.states).size, f.states.length);
  await stop(f);
});

test('unobserve, listener replacement and self-unsubscription leave no stale listeners', async () => {
  const f = setup();
  const oldCount = f.states.length;
  let received = 0;
  f.controller.observe(() => { received++; });
  f.start();
  await flush();
  assert.equal(f.states.length, oldCount);
  assert.ok(received > 1);
  f.controller.unobserve();
  const count = received;
  await f.clock.advance(500);
  await stop(f);
  assert.equal(received, count);
  let self = 0;
  f.controller.observe(() => { self++; f.controller.unobserve(); });
  f.start();
  await flush();
  await stop(f);
  assert.equal(self, 1);
});

test('retained source predicates and timer callbacks never become current after a restart', async () => {
  const f = setup();
  f.start();
  await flush();
  const prepareCurrent = f.data.prepareCurrent;
  const frameCurrent = f.data.frames[0].isCurrent;
  const oldStatus = f.clock.pending(true)[0].callback;
  assert.equal(prepareCurrent(), true);
  await stop(f);
  f.start();
  await flush();
  assert.equal(f.controller.isBusy(), true);
  assert.equal(prepareCurrent(), false);
  assert.equal(frameCurrent(), false);
  oldStatus();
  assert.equal(f.controller.isBusy(), true);
  assert.equal(f.state.phase, 'running');
  await stop(f);
});

test('source and listener mutations cannot alter owned frames and disabled images stay empty', async () => {
  let raw;
  const f = setup({ next: () => { raw = frame(f.clock, 1, true); return raw; } });
  f.start();
  await flush();
  assert.equal(f.state.frame.imageUrl, '', 'Image mode must be enforced even if a source returns an image');
  const before = normalize(f.state.frame);
  raw.points[0].x = 9999;
  f.state.frame.points[1].x = -100;
  f.state.frame.imageUrl = 'unexpected';
  let fresh;
  f.controller.observe(state => { fresh = state; });
  assert.deepEqual(normalize(fresh.frame), before);
  await stop(f);
});

test('cleanup failure keeps the camera locked until explicit successful cleanup retry', async () => {
  let fails = true;
  const f = setup({ dispose: () => { if (fails) throw Error('camera still owned'); } });
  f.start();
  await flush();
  await completed(f.controller.stop());
  assert.equal(f.state.cleanupBlocked, true);
  assert.equal(f.controller.isBusy(), true);
  const accessCount = f.accesses;
  f.start();
  await flush();
  assert.equal(f.accesses, accessCount);
  fails = false;
  await completed(f.controller.stop());
  assert.equal(f.state.cleanupBlocked, false);
  assert.equal(f.controller.isBusy(), false);
  assert.equal(f.data.disposes, 2);
  f.start();
  await flush();
  assert.equal(f.accesses, accessCount + 1);
  await stop(f);
});

test('a frame listener can stop reentrantly without another capture or duplicate disposal', async () => {
  const f = setup();
  let stopping;
  f.controller.observe(state => { if (state.frame) stopping = tracked(f.controller.stop()); });
  f.start();
  await flush();
  assert.ok(stopping);
  assert.equal(stopping.settled, true);
  assert.equal(stopping.error, undefined);
  assert.equal(f.data.frames.length, 1);
  assert.equal(f.data.disposes, 1);
  assert.equal(f.controller.isBusy(), false);
  assert.equal(f.clock.tasks.size, 0);
});

test('stop reentered from the preparing listener still waits for asynchronous disposal', async () => {
  const disposal = deferred();
  const f = setup({ dispose: () => disposal.promise });
  let stopping;
  f.controller.observe(state => { if (state.phase === 'preparing') stopping = tracked(f.controller.stop()); });
  f.start();
  await flush();
  assert.ok(stopping);
  assert.equal(f.controller.isBusy(), true);
  assert.equal(f.data.disposes, 1);
  assert.equal(stopping.settled, false, 'A reentrant stop must not return a resolved placeholder operation');
  disposal.resolve();
  await flush();
  assert.equal(stopping.settled, true);
  assert.equal(f.controller.isBusy(), false);
});

function readOnly(value, violation, label = 'settings', cache = new WeakMap()) {
  if (value === null || typeof value !== 'object') return value;
  if (cache.has(value)) return cache.get(value);
  const proxy = new Proxy(value, {
    get(target, key) { return readOnly(target[key], violation, label + '.' + String(key), cache); },
    set() { return violation(label + ' write'); },
    deleteProperty() { return violation(label + ' delete'); },
    defineProperty() { return violation(label + ' defineProperty'); }
  });
  cache.set(value, proxy);
  return proxy;
}

function pageHarness(options = {}) {
  const model = load('models/LiveSkeletonMonitor');
  const calls = { order: [], permissions: 0, disposed: 0, observed: 0, starts: 0, stops: 0,
    previewStops: 0, runtime: 0, forbidden: [], context: {}, destroyed: 0 };
  const violation = name => { calls.forbidden.push(name); throw Error('Forbidden monitor side effect: ' + name); };
  let listener;
  const live = options.real ? setup(options.plan) : undefined;
  const controller = live?.controller ?? {
    observe(callback) { calls.observed++; listener = callback; callback(new model.LiveSkeletonState()); },
    unobserve() { listener = undefined; },
    start() { calls.starts++; },
    stop() { calls.stops++; return Promise.resolve(); },
    isBusy() { return false; },
    isRequested() { return calls.requested !== false; },
    setIncludeImage() {}
  };
  const pageMethods = ['openLiveSkeleton', 'closeLiveSkeleton', 'canRunLiveSkeleton', 'requestLiveSkeletonAccess',
    'controlsLocked', 'releasePostureSource', 'isCurrentPageRun', 'onForegroundChanged', 'aboutToDisappear'];
  for (const node of component('pages/Index', 'Index').members) {
    if (ts.isMethodDeclaration(node) && /LiveSkeleton/.test(node.name.getText(tree('pages/Index'))) &&
      !node.getText(tree('pages/Index')).startsWith('@Builder') && !pageMethods.includes(node.name.text)) {
      pageMethods.push(node.name.text);
    }
  }
  const Page = methodClass('pages/Index', 'Index', pageMethods, {
    ...model, CAMERA_PERMISSION: 'ohos.permission.CAMERA',
    evaluatePosture: () => violation('evaluatePosture'),
    PostureSessionStore: { save: () => violation('store.save') },
    ReminderFeedbackService: { notify: () => violation('notification'), pulsePair: () => violation('vibration') },
    WearableReminderService: { destroy: () => { calls.destroyed++; },
      controller: { submit: () => violation('wearable.submit') } },
    abilityAccessCtrl: { GrantStatus: { PERMISSION_GRANTED: 0 }, createAtManager() {
      calls.order.push('permission-manager');
      return { async requestPermissionsFromUser(context, permissions) {
        calls.permissions++;
        calls.order.push('permission');
        assert.equal(context, calls.context);
        assert.deepEqual([...permissions], ['ohos.permission.CAMERA']);
        return calls.permissionHandler ? calls.permissionHandler() : { authResults: [0] };
      } };
    } }
  });
  const p = Object.assign(new Page(), { loaded: true, appForeground: true, showLiveSkeleton: false,
    liveSkeletonBusy: false, liveSkeletonClosing: false, liveSkeletonState: new model.LiveSkeletonState(),
    isManualOperation: false, isStartingGuard: false, isStoppingGuard: false, isGuarding: false,
    isCalibrating: false, isSampling: false, sourceDisposal: undefined, pageRunId: 1, activeTab: 3,
    showDebugPanel: false, wearablePageId: 1, wearablePageVisible: true, calibrationCancelled: false,
    score: 87, summary: 'unchanged summary', lastSample: undefined, reminderText: 'unchanged reminder',
    liveSkeletonController: controller,
    abilityContext() { calls.order.push('context'); return calls.context; },
    syncWearableRuntime() { calls.runtime++; },
    stopReminderPreview() { calls.previewStops++; },
    stopLowScoreReminders() {}, stopGuard: async () => {},
    postureSource: { async dispose() {
      calls.disposed++;
      calls.order.push('dispose-start');
      await calls.disposeHandler?.();
      calls.order.push('dispose-end');
    }, sample: () => violation('postureSource.sample') },
    reminder: { feed: () => violation('reminder.feed') },
    lowScoreScheduler: { feed: () => violation('lowScoreScheduler.feed') }
  });
  const settings = load('models/PostureTypes').createDefaultSettings();
  settings.useCoreVision = options.useCoreVision ?? true;
  const protectedSettings = readOnly(settings, violation);
  const records = readOnly([{ timestamp: 123, score: 87 }], violation, 'records');
  Object.defineProperty(p, 'settings', { get: () => protectedSettings, set: () => violation('settings replacement') });
  Object.defineProperty(p, 'records', { get: () => records, set: () => violation('records replacement') });
  for (const name of ['evaluatePosture', 'persistData', 'appendRecord', 'applyResult', 'runCalibration',
    'captureFrame', 'sampleOnce', 'calibrateFromCurrent', 'rebuildPostureSource', 'createPostureSource',
    'dispatchLowScoreFeedback', 'applyLowScoreDecision']) p[name] = () => violation(name);
  const snapshot = () => normalize({ settings: p.settings, records: p.records, score: p.score,
    summary: p.summary, lastSample: p.lastSample, reminderText: p.reminderText });
  const before = snapshot();
  return { p, calls, controller, live,
    publish: state => { assert.ok(listener); listener(state); },
    assertIsolated() {
      assert.deepEqual(calls.forbidden, []);
      assert.equal(p.settings, protectedSettings);
      assert.equal(p.records, records);
      assert.deepEqual(snapshot(), before);
    }
  };
}

function componentOptions(file, name, method, callee, subject, dependencies = {}) {
  const found = calls(member(file, name, method), callee);
  assert.equal(found.length, 1, `Expected one ${method}:${callee}`);
  return evaluate(found[0].arguments[0].getText(tree(file)), subject, dependencies);
}

function coverCallback(subject, name) {
  const cover = calls(member('pages/Index', 'Index', 'build'), 'bindContentCover');
  assert.equal(cover.length, 1, 'Monitor must use an independent content cover');
  const options = cover[0].arguments[2];
  const callback = options.properties.find(node => node.name?.getText(tree('pages/Index')) === name);
  if (callback) evaluate(callback.initializer.getText(tree('pages/Index')), subject)();
}

test('actual Index open rejects unloaded, guarding, calibrating, manual, sampling and source-disposal states', () => {
  for (const patch of [{ loaded: false }, { appForeground: false }, { isGuarding: true },
    { isCalibrating: true }, { isManualOperation: true }, { isStartingGuard: true }, { isStoppingGuard: true },
    { isSampling: true }, { sourceDisposal: Promise.resolve() }, { showLiveSkeleton: true },
    { liveSkeletonBusy: true }]) {
    const f = pageHarness();
    Object.assign(f.p, patch);
    f.p.openLiveSkeleton();
    assert.equal(f.p.showLiveSkeleton, patch.showLiveSkeleton === true, JSON.stringify(patch));
    assert.equal(f.calls.observed, 0);
    assert.equal(f.calls.permissions, 0);
    assert.equal(f.calls.disposed, 0);
    assert.equal(f.calls.previewStops, 0);
    assert.equal(f.calls.starts, 0);
    f.assertIsolated();
  }
});

test('actual Index controlsLocked includes both live visibility and release busy state', () => {
  const f = pageHarness();
  assert.equal(f.p.controlsLocked(), false);
  for (const key of ['isManualOperation', 'isStartingGuard', 'isStoppingGuard', 'showLiveSkeleton', 'liveSkeletonBusy']) {
    f.p[key] = true;
    assert.equal(f.p.controlsLocked(), true, key);
    f.p[key] = false;
  }
  assert.equal(f.p.controlsLocked(), false);
  f.assertIsolated();
});

test('actual Index canRun guards each conflict without deadlocking on its own controller busy flag', () => {
  const f = pageHarness({ useCoreVision: false });
  f.p.showLiveSkeleton = true;
  f.p.liveSkeletonBusy = true;
  assert.equal(f.p.canRunLiveSkeleton(), true, 'Standalone monitor does not depend on posture-source settings');
  for (const [key, blocked] of [['loaded', false], ['appForeground', false], ['showLiveSkeleton', false],
    ['isGuarding', true], ['isCalibrating', true], ['isManualOperation', true], ['isStartingGuard', true],
    ['isStoppingGuard', true], ['isSampling', true]]) {
    const saved = f.p[key];
    f.p[key] = blocked;
    assert.equal(f.p.canRunLiveSkeleton(), false, key);
    f.p[key] = saved;
  }
  f.assertIsolated();
});

test('actual Index opening only subscribes; phase snapshots keep controls locked through close and disposal', () => {
  const f = pageHarness();
  f.p.openLiveSkeleton();
  assert.equal(f.p.showLiveSkeleton, true);
  assert.equal(f.calls.previewStops, 1);
  assert.equal(f.calls.observed, 1);
  assert.equal(f.calls.starts, 0);
  assert.equal(f.calls.permissions, 0);
  for (const phase of ['preparing', 'running', 'stopping', 'idle', 'error']) {
    const state = { phase, detail: phase, cleanupBlocked: false };
    f.publish(state);
    assert.equal(f.p.liveSkeletonState, state);
    assert.equal(f.p.liveSkeletonBusy, ['preparing', 'running', 'stopping'].includes(phase));
  }
  f.publish({ phase: 'running' });
  f.p.closeLiveSkeleton();
  assert.equal(f.p.showLiveSkeleton, false);
  assert.equal(f.calls.stops, 1);
  assert.equal(f.p.controlsLocked(), true);
  f.p.openLiveSkeleton();
  assert.equal(f.calls.observed, 1);
  f.publish({ phase: 'stopping' });
  assert.equal(f.p.liveSkeletonBusy, true);
  f.publish({ phase: 'idle', cleanupBlocked: false });
  coverCallback(f.p, 'onDisappear');
  assert.equal(f.p.controlsLocked(), false);
  f.assertIsolated();
});

test('cleanup-blocked errors keep Index camera controls locked and expose explicit recovery', () => {
  const f = pageHarness();
  f.p.openLiveSkeleton();
  f.publish({ phase: 'error', cleanupBlocked: true });
  f.p.closeLiveSkeleton();
  coverCallback(f.p, 'onDisappear');
  assert.equal(f.p.liveSkeletonBusy, true);
  assert.equal(f.p.controlsLocked(), true);
  const callback = evaluate(controlArgument('pages/Index', 'Index', 'live-skeleton-retry-release',
    'onClick', 'LiveSkeletonEntry'), f.p);
  callback();
  assert.equal(f.calls.stops, 2);
  f.publish({ phase: 'idle', cleanupBlocked: false });
  assert.equal(f.p.controlsLocked(), false);
  f.assertIsolated();
});

test('modal dismissal stays locked through its animation even when the controller is already idle', () => {
  const f = pageHarness();
  f.p.openLiveSkeleton();
  f.p.showLiveSkeleton = false;
  coverCallback(f.p, 'onWillDisappear');
  assert.equal(f.p.liveSkeletonClosing, true);
  f.p.openLiveSkeleton();
  assert.equal(f.p.showLiveSkeleton, false);
  coverCallback(f.p, 'onDisappear');
  f.p.openLiveSkeleton();
  assert.equal(f.p.showLiveSkeleton, true);
});

test('actual Index waits for source disposal before permission and joins an existing disposal exactly once', async () => {
  const f = pageHarness({ useCoreVision: false });
  f.p.openLiveSkeleton();
  const disposal = deferred();
  f.calls.disposeHandler = () => disposal.promise;
  const releasing = f.p.releasePostureSource();
  const access = tracked(f.p.requestLiveSkeletonAccess());
  await flush();
  assert.equal(f.calls.disposed, 1);
  assert.equal(f.calls.permissions, 0, 'Permission prompt must not race the existing camera owner');
  assert.equal(f.calls.order.includes('context'), false);
  assert.equal(access.settled, false);
  disposal.resolve();
  await completed(releasing);
  await flush();
  assert.equal(access.value, true);
  assert.equal(f.calls.permissions, 1);
  assert.ok(f.calls.order.indexOf('dispose-end') < f.calls.order.indexOf('permission'));
  assert.equal(f.p.sourceDisposal, undefined);
  assert.equal(f.p.settings.useCoreVision, false);
  f.assertIsolated();
});

for (const stage of ['disposal', 'permission']) {
  test(`actual Index rechecks cancellation after awaited ${stage}`, async () => {
    for (const patch of [{ loaded: false }, { appForeground: false }, { showLiveSkeleton: false },
      { isGuarding: true }, { isCalibrating: true }, { isManualOperation: true }, { isStartingGuard: true },
      { isStoppingGuard: true }, { isSampling: true }]) {
      const f = pageHarness();
      f.p.openLiveSkeleton();
      const gate = deferred(stage === 'permission' ? { authResults: [0] } : undefined);
      if (stage === 'disposal') f.calls.disposeHandler = () => gate.promise;
      else f.calls.permissionHandler = () => gate.promise;
      const access = tracked(f.p.requestLiveSkeletonAccess());
      await flush();
      assert.equal(access.settled, false);
      Object.assign(f.p, patch);
      gate.resolve(stage === 'permission' ? { authResults: [0] } : undefined);
      await flush();
      assert.equal(access.settled, true, JSON.stringify(patch));
      assert.equal(access.error, undefined);
      assert.equal(access.value, false, JSON.stringify(patch));
      assert.equal(f.calls.permissions, stage === 'permission' ? 1 : 0);
      f.assertIsolated();
    }
  });
}

test('actual Index permission failures and missing context never enable the monitor', async () => {
  for (const mode of ['context', 'denied', 'empty', 'error', 'locked']) {
    const f = pageHarness();
    f.p.openLiveSkeleton();
    if (mode === 'context') f.calls.context = undefined;
    if (mode === 'locked') f.p.isSampling = true;
    f.calls.permissionHandler = async () => {
      if (mode === 'error') throw Error('permission service failed');
      return { authResults: mode === 'empty' ? [] : [-1] };
    };
    assert.equal(await completed(f.p.requestLiveSkeletonAccess()), false, mode);
    assert.equal(f.calls.disposed, mode === 'locked' ? 0 : 1);
    assert.equal(f.calls.permissions, mode === 'locked' || mode === 'context' ? 0 : 1);
    f.assertIsolated();
  }
});

test('explicit stop during old-source disposal cannot open a late permission dialog', async () => {
  const f = pageHarness();
  f.p.openLiveSkeleton();
  const disposal = deferred();
  f.calls.disposeHandler = () => disposal.promise;
  const access = tracked(f.p.requestLiveSkeletonAccess());
  await flush();
  assert.equal(access.settled, false);
  f.calls.requested = false;
  disposal.resolve();
  await flush();
  assert.equal(access.value, false);
  assert.equal(f.calls.permissions, 0);
  f.assertIsolated();
});

test('actual Index plus controller performs standalone capture with useCoreVision false and preserves all user data', async () => {
  const disposal = deferred();
  const f = pageHarness({ real: true, useCoreVision: false, plan: { dispose: () => disposal.promise } });
  f.p.openLiveSkeleton();
  const start = () => f.controller.start(f.live.source,
    () => f.p.requestLiveSkeletonAccess(), () => f.p.canRunLiveSkeleton());
  start();
  await flush();
  await f.live.clock.advance(500);
  assert.equal(f.calls.permissions, 1, 'Standalone real camera access cannot be skipped in simulated posture mode');
  assert.equal(f.calls.disposed, 1);
  assert.equal(f.live.data.prepares, 1);
  assert.equal(f.live.data.frames.length, 6);
  assert.equal(f.p.liveSkeletonState.phase, 'running');
  assert.equal(f.p.liveSkeletonBusy, true);
  f.controller.setIncludeImage(true);
  await f.live.clock.advance(100);
  assert.ok(f.p.liveSkeletonState.frame.imageUrl);
  f.controller.setIncludeImage(false);
  assert.equal(f.p.liveSkeletonState.frame, undefined);
  f.p.closeLiveSkeleton();
  await flush();
  assert.equal(f.p.showLiveSkeleton, false);
  assert.equal(f.p.liveSkeletonBusy, true);
  assert.equal(f.p.controlsLocked(), true);
  f.p.openLiveSkeleton();
  assert.equal(f.p.showLiveSkeleton, false);
  start();
  assert.equal(f.calls.permissions, 1);
  disposal.resolve();
  await flush();
  coverCallback(f.p, 'onDisappear');
  assert.equal(f.p.liveSkeletonBusy, false);
  assert.equal(f.p.controlsLocked(), false);
  f.p.openLiveSkeleton();
  assert.equal(f.p.showLiveSkeleton, true);
  f.assertIsolated();
});

test('actual Index background and disappearance stop pending access without automatically resuming', async () => {
  for (const disappear of [false, true]) {
    const f = pageHarness({ real: true });
    f.p.openLiveSkeleton();
    const permission = deferred({ authResults: [0] });
    f.calls.permissionHandler = () => permission.promise;
    f.controller.start(f.live.source, () => f.p.requestLiveSkeletonAccess(), () => f.p.canRunLiveSkeleton());
    await flush();
    if (disappear) f.p.aboutToDisappear();
    else { f.p.appForeground = false; f.p.onForegroundChanged(); }
    permission.resolve({ authResults: [0] });
    await flush();
    assert.equal(f.controller.isBusy(), false);
    assert.equal(f.live.data.prepares, 0);
    assert.equal(f.live.data.disposes, 1);
    assert.equal(f.p.liveSkeletonState.frame, undefined);
    f.p.appForeground = true;
    f.p.onForegroundChanged();
    await f.live.clock.advance(500);
    assert.equal(f.live.data.prepares, 0);
    assert.equal(f.calls.permissions, 1);
    f.assertIsolated();
  }
});

test('actual debug-panel bindings disable inspection when live monitoring is visible or busy', () => {
  const f = pageHarness();
  const props = () => componentOptions('pages/Index', 'Index', 'DeveloperDebugPanel', 'SkeletonDebugPanel', f.p);
  assert.equal(props().active, true);
  for (const patch of [{ showLiveSkeleton: true }, { liveSkeletonBusy: true }, { appForeground: false }, { activeTab: 0 }]) {
    const before = { showLiveSkeleton: false, liveSkeletonBusy: false, appForeground: true, activeTab: 3 };
    Object.assign(f.p, before, patch);
    assert.equal(props().active, false, JSON.stringify(patch));
    if (patch.showLiveSkeleton || patch.liveSkeletonBusy) assert.equal(props().locked, true);
  }
  f.assertIsolated();
});

test('settings expose the live entry outside developer tools and wire the actual modal callbacks', async () => {
  const f = pageHarness();
  const settings = member('pages/Index', 'Index', 'SettingsPage');
  const entryCalls = calls(settings, 'LiveSkeletonEntry');
  assert.equal(entryCalls.length, 1);
  let ancestor = entryCalls[0].parent;
  while (ancestor && ancestor !== settings) {
    assert.equal(ts.isIfStatement(ancestor) || ts.isConditionalExpression(ancestor), false,
      'Live monitor entry must not depend on developer-tool visibility');
    ancestor = ancestor.parent;
  }
  assert.equal(calls(member('pages/Index', 'Index', 'DeveloperDebugPanel'), 'LiveSkeletonEntry').length, 0);
  const enabled = () => evaluate(controlArgument('pages/Index', 'Index', 'live-skeleton-open',
    'enabled', 'LiveSkeletonEntry'), f.p);
  assert.equal(enabled(), true);
  f.p.showDebugPanel = false;
  evaluate(controlArgument('pages/Index', 'Index', 'live-skeleton-open', 'onClick', 'LiveSkeletonEntry'), f.p)();
  assert.equal(f.p.showLiveSkeleton, true);
  assert.equal(enabled(), false);
  const props = componentOptions('pages/Index', 'Index', 'LiveSkeletonPage', 'LiveSkeletonMonitorView', f.p);
  assert.equal(props.controller, f.controller);
  assert.equal(props.monitorState, f.p.liveSkeletonState);
  assert.equal(props.foreground, true);
  assert.equal(props.contextProvider(), f.calls.context);
  assert.equal(props.canRun(), true);
  assert.equal(await completed(props.requestAccess()), true);
  props.onClose();
  assert.equal(f.p.showLiveSkeleton, false);
  assert.equal(f.calls.stops, 1);
  coverCallback(f.p, 'onWillDisappear');
  assert.equal(f.calls.stops, 2, 'System back/cover dismissal must also stop');
  coverCallback(f.p, 'onDisappear');
  f.assertIsolated();
});

function viewHarness() {
  const model = load('models/LiveSkeletonMonitor');
  const clock = new Clock();
  const data = { starts: [], stops: 0, images: [], sources: [], context: {}, allowed: true, busy: false, accesses: 0 };
  const controller = { setIncludeImage: value => data.images.push(value), isBusy: () => data.busy,
    start: (...args) => data.starts.push(args), stop: () => { data.stops++; return Promise.resolve(); }, unobserve() {} };
  const View = methodClass('components/LiveSkeletonMonitorView', 'LiveSkeletonMonitorView',
    ['aboutToAppear', 'aboutToDisappear', 'availabilityChanged', 'start', 'isActive', 'actionText'], {
      ...model, LiveSkeletonCameraSource: class {
        constructor(context) {
          assert.equal(context, data.context);
          Object.assign(this, fakeSource(clock).source);
          data.sources.push(this);
        }
      }
    });
  const view = Object.assign(new View(), { controller, visible: false, foreground: true, withImage: false,
    mirrored: true, monitorState: new model.LiveSkeletonState(),
    contextProvider: () => data.context, canRun: () => data.allowed,
    requestAccess: async () => { data.accesses++; return true; }, onClose: () => { data.closed = true; } });
  const callback = (id, attribute) => evaluate(controlArgument('components/LiveSkeletonMonitorView',
    'LiveSkeletonMonitorView', id, attribute), view, model);
  return { view, data, callback, clock };
}

test('actual monitor lifecycle stops on disappearance/background and never starts on appear or foreground return', () => {
  const f = viewHarness();
  const initial = key => evaluate(member('components/LiveSkeletonMonitorView',
    'LiveSkeletonMonitorView', key).initializer.getText(tree('components/LiveSkeletonMonitorView')), {});
  assert.equal(initial('withImage'), false);
  assert.equal(initial('mirrored'), true);
  f.view.aboutToAppear();
  assert.equal(f.view.visible, true);
  assert.deepEqual(f.data.images, [false]);
  assert.equal(f.data.starts.length, 0);
  f.view.foreground = false;
  f.view.availabilityChanged();
  assert.equal(f.data.stops, 1);
  f.view.foreground = true;
  f.view.availabilityChanged();
  assert.equal(f.data.starts.length, 0);
  f.view.aboutToDisappear();
  assert.equal(f.view.visible, false);
  assert.equal(f.data.stops, 2);
  f.view.aboutToAppear();
  assert.equal(f.data.starts.length, 0);
});

test('actual monitor start guards visibility, foreground, canRun, busy and missing context', async () => {
  for (const mode of ['invisible', 'background', 'disallowed', 'busy', 'context', 'allowed']) {
    const f = viewHarness();
    f.view.aboutToAppear();
    if (mode === 'invisible') f.view.visible = false;
    if (mode === 'background') f.view.foreground = false;
    if (mode === 'disallowed') f.data.allowed = false;
    if (mode === 'busy') f.data.busy = true;
    if (mode === 'context') f.data.context = undefined;
    f.view.start();
    assert.equal(f.data.starts.length, mode === 'allowed' ? 1 : 0, mode);
    if (mode === 'context') assert.equal(f.view.monitorState.phase, 'error');
    if (mode !== 'allowed') continue;
    const [source, access, isCurrent] = f.data.starts[0];
    assert.equal(source, f.data.sources[0]);
    assert.equal(access, f.view.requestAccess);
    assert.equal(await access(), true);
    assert.equal(isCurrent(), true);
    f.view.foreground = false;
    assert.equal(isCurrent(), false);
    f.view.foreground = true;
    f.data.allowed = false;
    assert.equal(isCurrent(), false);
    f.data.allowed = true;
    f.view.aboutToDisappear();
    assert.equal(isCurrent(), false);
  }
});

test('actual monitor start/stop/back/image/mirror callbacks execute without rendering or touching the camera source', () => {
  const f = viewHarness();
  f.view.aboutToAppear();
  f.callback('live-skeleton-action', 'onClick')();
  assert.equal(f.data.starts.length, 1);
  f.view.monitorState.phase = 'running';
  assert.equal(f.view.isActive(), true);
  f.callback('live-skeleton-action', 'onClick')();
  assert.equal(f.data.stops, 1);
  f.view.monitorState.phase = 'preparing';
  f.callback('live-skeleton-action', 'onClick')();
  assert.equal(f.data.stops, 2);
  f.view.monitorState.phase = 'stopping';
  assert.equal(f.callback('live-skeleton-action', 'enabled'), false);
  f.view.monitorState.phase = 'idle';
  assert.equal(f.callback('live-skeleton-action', 'enabled'), true);
  f.view.foreground = false;
  assert.equal(f.callback('live-skeleton-action', 'enabled'), false);
  f.callback('live-skeleton-image-toggle', 'onChange')(true);
  assert.equal(f.view.withImage, true);
  assert.equal(f.data.images.at(-1), true);
  f.callback('live-skeleton-image-toggle', 'onChange')(false);
  assert.equal(f.view.withImage, false);
  assert.equal(f.data.images.at(-1), false);
  const imageCalls = f.data.images.length;
  f.callback('live-skeleton-mirror-toggle', 'onChange')(false);
  assert.equal(f.view.mirrored, false);
  f.callback('live-skeleton-mirror-toggle', 'onChange')(true);
  assert.equal(f.view.mirrored, true);
  assert.equal(f.data.images.length, imageCalls, 'Mirroring is presentation-only');
  f.callback('live-skeleton-close', 'onClick')();
  assert.equal(f.data.closed, true);
  assert.equal(f.data.starts.length, 1);
});

test('monitor image and skeleton rendering use the same frame and mirror property with measured FPS output', () => {
  const f = viewHarness();
  const current = frame(f.clock, 17, true);
  f.view.monitorState.frame = current;
  const renderers = calls(member('components/LiveSkeletonMonitorView', 'LiveSkeletonMonitorView', 'build'),
    'SkeletonFrameView');
  assert.equal(renderers.length, 2, 'Pure skeleton reuses Canvas; image mode recreates its same-frame pair');
  for (const renderer of renderers) {
    const props = evaluate(renderer.arguments[0].getText(tree('components/LiveSkeletonMonitorView')),
      f.view, { frame: current });
    assert.equal(props.frame, current);
    assert.equal(props.mirrored, true);
  }
  const fpsNode = calls(member('components/LiveSkeletonMonitorView', 'LiveSkeletonMonitorView', 'build'), 'id')
    .find(node => node.arguments[0]?.text === 'live-skeleton-fps');
  assert.ok(fpsNode);
  const text = calls(fpsNode, 'Text');
  assert.equal(text.length, 1);
  f.view.monitorState.fps = 3.125;
  assert.equal(evaluate(text[0].arguments[0].getText(tree('components/LiveSkeletonMonitorView')), f.view), '3.1 FPS');
});

test('monitor methods have no scoring, storage, notification, baseline, or posture-source sampling paths', () => {
  const forbidden = new Set(['evaluatePosture', 'captureFrame', 'sample', 'sampleOnce', 'appendRecord', 'persistData',
    'applyResult', 'runCalibration', 'buildCalibrationProfile', 'captureCalibration', 'dispatchLowScoreFeedback',
    'applyLowScoreDecision', 'feed', 'submit', 'notify', 'pulsePair', 'writeFile', 'writeFileSync', 'put', 'flush']);
  const monitored = [tree('models/LiveSkeletonMonitor'), tree('services/LiveSkeletonController'),
    tree('components/LiveSkeletonMonitorView'), ...['openLiveSkeleton', 'closeLiveSkeleton',
      'canRunLiveSkeleton', 'requestLiveSkeletonAccess'].map(name => member('pages/Index', 'Index', name))];
  for (const node of monitored) {
    for (const call of descendants(node, ts.isCallExpression)) {
      const name = ts.isPropertyAccessExpression(call.expression) ? call.expression.name.text : call.expression.getText();
      assert.equal(forbidden.has(name), false, 'Unexpected side effect call in monitor path: ' + call.getText());
    }
    for (const assignment of descendants(node, item => ts.isBinaryExpression(item) &&
      item.operatorToken.kind >= ts.SyntaxKind.FirstAssignment && item.operatorToken.kind <= ts.SyntaxKind.LastAssignment)) {
      assert.doesNotMatch(assignment.left.getText(), /\b(settings|profile|records)\b/);
    }
  }
});

function previous(file) {
  return execFileSync('git', ['show', `${baseline}:${file}`], { cwd: root, encoding: 'utf8', maxBuffer: 4 * 1024 * 1024 });
}

test('existing posture sources, evaluators, persistence, themes and native inference remain at the protected baseline', () => {
  const files = execFileSync('git', ['ls-tree', '-r', '--name-only', baseline, '--',
    sourceRoot + 'models', sourceRoot + 'services', sourceRoot + 'theme', 'entry/src/main/cpp',
    sourceRoot + 'components/StatusTiles.ets'], { cwd: root, encoding: 'utf8' }).trim().split('\n').filter(Boolean);
  assert.ok(files.length >= 20, 'Protected baseline must include the real source pipeline');
  for (const file of files) {
    if (file === sourceRoot + 'services/LiveSkeletonCameraSource.ets') continue;
    assert.equal(fs.readFileSync(path.join(root, file), 'utf8'), previous(file), 'Protected source changed: ' + file);
  }
});

test('Index header, navigation, source selection, scoring, calibration and statistics preserve the protected baseline', () => {
  const ast = ts.createSourceFile('PreviousIndex.ts', previous(sourceRoot + 'pages/Index.ets')
    .replace(/\bstruct\s+/g, 'class '), ts.ScriptTarget.Latest, true);
  const oldPage = ast.statements.find(node => ts.isClassDeclaration(node) && node.name?.text === 'Index');
  const oldMember = name => {
    const node = oldPage.members.find(item => item.name?.getText(ast) === name);
    assert.ok(node, 'Missing protected baseline member: ' + name);
    return node.getText(ast);
  };
  for (const name of ['Header', 'PageBody', 'BackgroundGlow', 'CameraSurfaceHost', 'switchTab',
    'createPostureSource', 'rebuildPostureSource', 'releasePostureSource', 'sampleSkeletonOnce',
    'startGuard', 'stopGuard', 'runCalibration', 'captureFrame', 'appendRecord', 'applyResult',
    'shouldAdoptMetric', 'setSensitivity', 'setIntervalMs', 'resetCalibration', 'buildSessionReport', 'copySettings']) {
    assert.equal(member('pages/Index', 'Index', name).getText(tree('pages/Index')), oldMember(name),
      'Protected Index method changed: ' + name);
  }
  const oldTabs = ast.statements.find(node => ts.isVariableStatement(node) &&
    node.declarationList.declarations.some(item => item.name.getText(ast) === 'TABS'));
  const newTabs = tree('pages/Index').statements.find(node => ts.isVariableStatement(node) &&
    node.declarationList.declarations.some(item => item.name.getText(tree('pages/Index')) === 'TABS'));
  assert.equal(newTabs.getText(tree('pages/Index')), oldTabs.getText(ast));
  const build = member('pages/Index', 'Index', 'build');
  const covers = calls(build, 'bindContentCover');
  assert.equal(covers.length, 1);
  const cover = covers[0];
  assert.equal(cover.arguments[0].getText(tree('pages/Index')), '$$this.showLiveSkeleton');
  const offset = build.getStart(tree('pages/Index'));
  const text = build.getText(tree('pages/Index'));
  const withoutCover = text.slice(0, cover.expression.expression.end - offset) + text.slice(cover.end - offset);
  assert.equal(withoutCover, oldMember('build'), 'Only the independent monitor content cover may change the root layout');
});

async function cleanup() {
  for (const f of resources.fixtures) {
    f.allowed = false;
    f.controller.unobserve();
    tracked(f.controller.stop());
  }
  for (let i = 0; i < 4; i++) {
    for (const gate of resources.gates) gate.resolve(gate.value);
    await flush();
  }
}

async function main() {
  let passed = 0;
  const failed = [];
  for (const group of tests) {
    resources = { fixtures: [], gates: [] };
    try {
      await group.run();
      passed++;
      console.log('PASS: ' + group.name);
    } catch (error) {
      failed.push(group.name);
      console.error('FAIL: ' + group.name);
      console.error(error.stack || error);
    } finally {
      await cleanup();
    }
  }
  console.log(`Live skeleton verification: ${passed}/${tests.length} groups passed; ${failed.length} failed.`);
  console.log('Controller/model: ' + sourceRoot + '{services/LiveSkeletonController,models/LiveSkeletonMonitor}.ets');
  console.log('Index/view: ' + sourceRoot + '{pages/Index,components/LiveSkeletonMonitorView}.ets');
  console.log('SDK transpiler: scripts/deveco-sdk.cjs; protected baseline: ' + baseline);
  console.log('LiveSkeletonCameraSource is neither loaded nor inspected; no build or device/UI operations.');
  if (failed.length) process.exitCode = 1;
}

main().catch(error => { console.error(error.stack || error); process.exitCode = 1; });
