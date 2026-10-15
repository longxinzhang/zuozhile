const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./deveco-sdk.cjs').typescript;

const root = path.resolve(__dirname, '..');
const file = path.join(root, 'entry/src/main/ets/services/ReminderFeedbackService.ets');
const compiled = ts.transpileModule(fs.readFileSync(file, 'utf8'), {
  fileName: 'ReminderFeedbackService.ts',
  compilerOptions: { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS },
  reportDiagnostics: true
});
assert.deepEqual(compiled.diagnostics || [], [], 'Feedback service must transpile without diagnostics');

function deferred() {
  let resolve;
  const promise = new Promise(done => { resolve = done; });
  return { promise, resolve };
}

async function flush() {
  for (let i = 0; i < 12; i++) await Promise.resolve();
}

function fixture(options = {}) {
  let now = 0, nextId = 0;
  const timers = new Map();
  const starts = [], stops = [], queries = [];
  const local = { deviceId: 9, vibratorId: 5, deviceName: 'local',
    isHdHapticSupported: false, isLocalVibrator: true };
  const remote = { deviceId: 44, vibratorId: 7, deviceName: 'remote',
    isHdHapticSupported: true, isLocalVibrator: false };
  const vibrator = {
    getVibratorInfoSync(param) {
      queries.push(param);
      if (options.queryError) throw new Error('query failed');
      return options.motors === 'none' ? [] : options.motors === 'remote' ? [remote] : [remote, local];
    },
    startVibration(effect, attribute) {
      starts.push({ effect: { ...effect }, attribute: { ...attribute }, at: now });
      return options.start ? options.start(starts.length) : Promise.resolve();
    },
    stopVibration() {
      stops.push(now);
      return options.stop ? options.stop(stops.length) : Promise.resolve();
    }
  };
  const module = { exports: {} };
  vm.runInNewContext(compiled.outputText, {
    module, exports: module.exports, console,
    require(name) {
      assert.equal(name, '@kit.SensorServiceKit', 'Feedback must not import audio or other side-effect services');
      return { vibrator };
    },
    canIUse(name) {
      assert.equal(name, 'SystemCapability.Sensors.MiscDevice');
      return options.capable !== false;
    },
    setTimeout(callback, duration) {
      const id = nextId++;
      timers.set(id, { callback, duration, at: now + duration });
      return id;
    },
    clearTimeout(id) { timers.delete(id); }
  }, { filename: file });
  function advance(duration) {
    now += duration;
    for (const [id, timer] of [...timers]) {
      if (timer.at <= now) {
        timers.delete(id);
        timer.callback();
      }
    }
  }
  return {
    service: module.exports.ReminderFeedbackService, timers, starts, stops, queries, advance,
    fire() {
      assert.equal(timers.size, 1, 'Exactly one delayed second pulse must be pending');
      const timer = timers.values().next().value;
      advance(timer.at - now);
    }
  };
}

let checks = 0;
async function check(name, run) {
  let watchdog;
  try {
    await Promise.race([
      run(),
      new Promise((resolve, reject) => {
        watchdog = setTimeout(() => reject(new Error('Timed out: ' + name)), 2000);
      })
    ]);
  } finally {
    clearTimeout(watchdog);
  }
  checks++;
  console.log('PASS: ' + name);
}

async function main() {
  await check('80ms pulses separated by 120ms, local motor only, one start event', async () => {
    const f = fixture();
    let events = 0;
    assert.equal(f.service.isAvailable(), true);
    assert.equal(f.service.isAvailable(), true);
    assert.equal(f.queries.length, 1);
    assert.equal(f.queries[0], undefined);
    const result = f.service.pulsePair(() => true, () => { events++; });
    await flush();
    assert.equal(f.starts.length, 1);
    assert.equal(events, 1);
    assert.equal(f.timers.values().next().value.duration, 200);
    f.advance(80);
    await flush();
    assert.equal(f.starts.length, 1);
    f.advance(119);
    await flush();
    assert.equal(f.starts.length, 1);
    f.fire();
    assert.equal(await result, true);
    assert.equal(f.starts.length, 2);
    for (const start of f.starts) {
      assert.deepEqual(start.effect, { type: 'time', duration: 80 });
      assert.deepEqual(start.attribute, { deviceId: -1, id: 5, usage: 'notification' });
    }
    assert.equal(f.starts[1].at - f.starts[0].at - 80, 120);
    assert.equal(events, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('stop while initial stop is pending cannot resurrect first pulse', async () => {
    const gate = deferred();
    const f = fixture({ stop: () => gate.promise });
    const result = f.service.pulsePair(() => true, () => assert.fail('stale event'));
    const stopped = f.service.stop();
    gate.resolve();
    assert.equal(await result, false);
    await stopped;
    assert.equal(f.starts.length, 0);
    assert.equal(f.timers.size, 0);
  });

  await check('isCurrent invalidation across initial stop blocks first pulse', async () => {
    const gate = deferred();
    const f = fixture({ stop: () => gate.promise });
    let current = true;
    const result = f.service.pulsePair(() => current, () => assert.fail('stale event'));
    current = false;
    gate.resolve();
    assert.equal(await result, false);
    assert.equal(f.starts.length, 0);
    assert.equal(f.timers.size, 0);

    const reentryGate = deferred();
    const reentry = fixture({ stop: count => count === 1 ? reentryGate.promise : Promise.resolve() });
    let cancelOnCheck = false, stopped;
    const cancelled = reentry.service.pulsePair(() => {
      if (cancelOnCheck) {
        cancelOnCheck = false;
        stopped = reentry.service.stop();
      }
      return true;
    }, () => assert.fail('reentrant stop must invalidate the generation'));
    cancelOnCheck = true;
    reentryGate.resolve();
    assert.equal(await cancelled, false);
    await stopped;
    assert.equal(reentry.starts.length, 0);
  });

  await check('late first start acknowledgement after stop cannot call event or second pulse', async () => {
    const gate = deferred();
    const f = fixture({ start: () => gate.promise });
    const result = f.service.pulsePair(() => true, () => assert.fail('stale event'));
    await flush();
    assert.equal(f.starts.length, 1);
    await f.service.stop();
    gate.resolve();
    assert.equal(await result, true);
    assert.equal(f.timers.size, 0);
    assert.equal(f.starts.length, 1);
  });

  await check('isCurrent invalidation across first start blocks event and second pulse', async () => {
    const gate = deferred();
    const f = fixture({ start: () => gate.promise });
    let current = true;
    const result = f.service.pulsePair(() => current, () => assert.fail('stale event'));
    await flush();
    assert.equal(f.starts.length, 1);
    current = false;
    gate.resolve();
    assert.equal(await result, true);
    assert.equal(f.starts.length, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('stop synchronously clears and resolves delay even with hardware stop pending', async () => {
    for (const elapsed of [0, 40, 80, 199]) {
      const gate = deferred();
      const f = fixture({ stop: count => count === 1 ? Promise.resolve() : gate.promise });
      let events = 0;
      const result = f.service.pulsePair(() => true, () => { events++; });
      await flush();
      const staleTimer = f.timers.values().next().value.callback;
      f.advance(elapsed);
      const stopped = f.service.stop();
      assert.equal(f.timers.size, 0);
      assert.equal(await result, true);
      staleTimer();
      await flush();
      assert.equal(f.starts.length, 1);
      assert.equal(events, 1);
      gate.resolve();
      await stopped;
      assert.equal(f.timers.size, 0);
    }
  });

  await check('stop after timer resolution but before continuation blocks second pulse', async () => {
    const f = fixture();
    let events = 0;
    const result = f.service.pulsePair(() => true, () => { events++; });
    await flush();
    f.fire();
    const stopped = f.service.stop();
    assert.equal(await result, true);
    await stopped;
    assert.equal(f.starts.length, 1);
    assert.equal(events, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('isCurrent false at delayed callback or continuation blocks second pulse', async () => {
    for (const phase of ['callback', 'continuation']) {
      const f = fixture();
      let current = true, events = 0;
      const result = f.service.pulsePair(() => current, () => { events++; });
      await flush();
      if (phase === 'callback') current = false;
      f.fire();
      current = false;
      assert.equal(await result, true);
      assert.equal(f.starts.length, 1);
      assert.equal(events, 1);
      assert.equal(f.timers.size, 0);
    }
  });

  await check('onStarted may synchronously stop without creating delayed second pulse', async () => {
    const f = fixture();
    let events = 0, stopped;
    const result = f.service.pulsePair(() => true, () => {
      events++;
      stopped = f.service.stop();
    });
    assert.equal(await result, true);
    await stopped;
    assert.equal(events, 1);
    assert.equal(f.starts.length, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('replaced generation cannot clear new timer or trigger old second pulse', async () => {
    const f = fixture();
    let firstEvents = 0, secondEvents = 0;
    const first = f.service.pulsePair(() => true, () => { firstEvents++; });
    await flush();
    const staleTimer = f.timers.values().next().value.callback;
    const second = f.service.pulsePair(() => true, () => { secondEvents++; });
    await flush();
    assert.equal(await first, true);
    assert.equal(f.timers.size, 1);
    staleTimer();
    await flush();
    assert.equal(f.timers.size, 1);
    assert.equal(f.starts.length, 2);
    f.fire();
    assert.equal(await second, true);
    assert.equal(f.starts.length, 3);
    assert.equal(firstEvents, 1);
    assert.equal(secondEvents, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('first start rejection permanently disables vibration without retries', async () => {
    const f = fixture({ start: () => Promise.reject(new Error('start failed')) });
    assert.equal(await f.service.pulsePair(() => true, () => assert.fail('failed event')), false);
    assert.equal(f.service.isAvailable(), false);
    await f.service.stop();
    assert.equal(await f.service.pulsePair(() => true, () => assert.fail('retry event')), false);
    assert.equal(f.starts.length, 1);
    assert.equal(f.stops.length, 1);
    assert.equal(f.queries.length, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('synchronous start throw disables vibration', async () => {
    const f = fixture({ start: () => { throw new Error('start failed'); } });
    assert.equal(await f.service.pulsePair(() => true, () => assert.fail('failed event')), false);
    assert.equal(f.service.isAvailable(), false);
    assert.equal(await f.service.pulsePair(() => true, () => assert.fail('retry event')), false);
    assert.equal(f.starts.length, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('second start failure keeps first success and one event, disables future starts', async () => {
    for (const synchronous of [false, true]) {
      const f = fixture({ start: count => {
        if (count === 1) return Promise.resolve();
        if (synchronous) throw new Error('second pulse failed');
        return Promise.reject(new Error('second pulse failed'));
      } });
      let events = 0;
      const result = f.service.pulsePair(() => true, () => { events++; });
      await flush();
      f.fire();
      assert.equal(await result, true);
      assert.equal(events, 1);
      assert.equal(f.service.isAvailable(), false);
      await f.service.stop();
      assert.equal(await f.service.pulsePair(() => true, () => assert.fail('retry event')), false);
      assert.equal(f.starts.length, 2);
      assert.equal(f.stops.length, 1);
      assert.equal(f.timers.size, 0);
    }
  });

  await check('stop failure disables availability and blocks first pulse', async () => {
    for (const synchronous of [false, true]) {
      const f = fixture({ stop: () => {
        if (synchronous) throw new Error('stop failed');
        return Promise.reject(new Error('stop failed'));
      } });
      assert.equal(await f.service.pulsePair(() => true, () => assert.fail('failed event')), false);
      assert.equal(f.service.isAvailable(), false);
      await f.service.stop();
      assert.equal(await f.service.pulsePair(() => true, () => assert.fail('retry event')), false);
      assert.equal(f.starts.length, 0);
      assert.equal(f.stops.length, 1);
      assert.equal(f.timers.size, 0);
    }
  });

  await check('no local motor, remote-only motors, unsupported capability and query errors stay unavailable', async () => {
    for (const options of [{ motors: 'none' }, { motors: 'remote' }, { capable: false }, { queryError: true }]) {
      const f = fixture(options);
      assert.equal(f.service.isAvailable(), false);
      assert.equal(f.service.isAvailable(), false);
      assert.equal(await f.service.pulsePair(() => true, () => assert.fail('unavailable event')), false);
      await f.service.stop();
      assert.equal(f.starts.length, 0);
      assert.equal(f.stops.length, 0);
      assert.equal(f.queries.length, options.capable === false ? 0 : 1);
      assert.equal(f.timers.size, 0);
    }
  });

  await check('not-current invocation performs no motor operations', async () => {
    const f = fixture();
    assert.equal(await f.service.pulsePair(() => false, () => assert.fail('inactive event')), false);
    assert.equal(f.starts.length, 0);
    assert.equal(f.stops.length, 0);
    assert.equal(f.queries.length, 0);
    assert.equal(f.timers.size, 0);
  });

  await check('concurrent initial stops completing out of order only start the newest pair', async () => {
    const firstStop = deferred(), secondStop = deferred();
    const f = fixture({ stop: count => count === 1 ? firstStop.promise : secondStop.promise });
    let events = 0;
    const first = f.service.pulsePair(() => true, () => assert.fail('superseded event'));
    const second = f.service.pulsePair(() => true, () => { events++; });
    await flush();
    assert.equal(f.starts.length, 0);
    secondStop.resolve();
    await flush();
    assert.equal(f.starts.length, 1);
    assert.equal(events, 1);
    firstStop.resolve();
    assert.equal(await first, false);
    assert.equal(f.starts.length, 1);
    assert.equal(f.timers.size, 1);
    f.fire();
    assert.equal(await second, true);
    assert.equal(f.starts.length, 2);
    assert.equal(events, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('a new request during pending stop survives old stop completion and stale callbacks', async () => {
    const externalStop = deferred(), newStop = deferred();
    const f = fixture({ stop: count => count === 1 ? Promise.resolve() :
      count === 2 ? externalStop.promise : newStop.promise });
    let firstEvents = 0, secondEvents = 0;
    const first = f.service.pulsePair(() => true, () => { firstEvents++; });
    await flush();
    const staleTimer = f.timers.values().next().value.callback;
    const stopped = f.service.stop();
    assert.equal(f.timers.size, 0);
    assert.equal(await first, true);
    assert.equal(await f.service.pulsePair(() => false, () => assert.fail('inactive reentry event')), false);
    assert.equal(f.stops.length, 2);
    const second = f.service.pulsePair(() => true, () => { secondEvents++; });
    await flush();
    assert.equal(f.starts.length, 1);
    newStop.resolve();
    await flush();
    assert.equal(f.starts.length, 2);
    assert.equal(f.timers.size, 1);
    externalStop.resolve();
    await stopped;
    staleTimer();
    await flush();
    assert.equal(f.timers.size, 1);
    assert.equal(f.starts.length, 2);
    f.fire();
    assert.equal(await second, true);
    assert.equal(f.starts.length, 3);
    assert.equal(firstEvents, 1);
    assert.equal(secondEvents, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('onStarted reentry replaces the old pair and fires once for each started request', async () => {
    const f = fixture();
    let firstEvents = 0, secondEvents = 0, second;
    const first = f.service.pulsePair(() => true, () => {
      firstEvents++;
      second = f.service.pulsePair(() => true, () => { secondEvents++; });
    });
    await flush();
    assert.equal(await first, true);
    assert.equal(firstEvents, 1);
    assert.equal(secondEvents, 1);
    assert.equal(f.starts.length, 2);
    assert.equal(f.timers.size, 1);
    f.fire();
    assert.equal(await second, true);
    assert.equal(f.starts.length, 3);
    assert.equal(firstEvents, 1);
    assert.equal(secondEvents, 1);
    assert.equal(f.timers.size, 0);
  });

  await check('cancellation during second start acknowledgement never repeats onStarted', async () => {
    for (const cancellation of ['stop', 'current']) {
      const gate = deferred();
      const f = fixture({ start: count => count === 1 ? Promise.resolve() : gate.promise });
      let current = true, events = 0, stopped;
      const result = f.service.pulsePair(() => current, () => { events++; });
      await flush();
      f.fire();
      await flush();
      assert.equal(f.starts.length, 2);
      assert.equal(events, 1);
      if (cancellation === 'stop') stopped = f.service.stop();
      else current = false;
      gate.resolve();
      assert.equal(await result, true);
      await stopped;
      assert.equal(f.starts.length, 2);
      assert.equal(events, 1);
      assert.equal(f.timers.size, 0);
    }
  });

  console.log(`PASS: ${checks} reminder feedback regression groups`);
}

main().catch(error => { console.error(error); process.exitCode = 1; });
