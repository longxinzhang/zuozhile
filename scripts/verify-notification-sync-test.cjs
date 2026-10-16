const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./deveco-sdk.cjs').typescript;

const root = path.resolve(__dirname, '..');
const sources = path.join(root, 'entry/src/main/ets');
const compilerOptions = { target: ts.ScriptTarget.ES2020, module: ts.ModuleKind.CommonJS };
const normalize = value => JSON.parse(JSON.stringify(value));

function deferred() {
  let resolve, reject;
  const promise = new Promise((done, fail) => { resolve = done; reject = fail; });
  return { promise, resolve, reject };
}

async function flush() {
  for (let i = 0; i < 60; i++) await Promise.resolve();
}

function fixture(options = {}) {
  let uptime = 100000, wall = Date.UTC(2026, 9, 15, 20), timerId = 0;
  const timers = new Map(), states = [];
  const calls = { queries: 0, permission: 0, slots: [], published: [], removed: [], tasks: [], released: [] };
  const config = { enabled: true, granted: false, transient: true, taskTime: 180000, taskId: 0, ...options };
  class TestDate extends Date { static now() { return wall; } }
  const context = { name: 'offline-only-ability-context' };
  const notificationManager = {
    SlotType: { SERVICE_INFORMATION: 2 },
    ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
    isNotificationEnabled() {
      calls.queries++;
      return config.query ? config.query(calls.queries) : Promise.resolve(config.enabled);
    },
    requestEnableNotification(value) {
      assert.equal(value, context); calls.permission++;
      if (config.permission) return config.permission();
      config.enabled = config.granted;
      return Promise.resolve();
    },
    addSlot(value) {
      calls.slots.push(value);
      return config.slot ? config.slot() : Promise.resolve();
    },
    publish(request) {
      calls.published.push({ request: normalize(request), uptime, wall });
      return config.publish ? config.publish(request) : Promise.resolve();
    },
    cancel(id, label) {
      calls.removed.push({ id, label });
      return config.clear ? config.clear() : Promise.resolve();
    }
  };
  const backgroundTaskManager = {
    requestSuspendDelay(reason, expired) {
      calls.tasks.push({ reason, expired });
      if (config.taskError) throw config.taskError;
      return { requestId: config.taskId, actualDelayTime: config.taskTime };
    },
    cancelSuspendDelay(id) {
      calls.released.push(id);
      if (config.releaseError) throw config.releaseError;
    }
  };
  const globals = {
    Date: TestDate, Error, console,
    setTimeout(callback, delay) {
      const id = ++timerId;
      timers.set(id, { callback, delay, due: uptime + delay });
      return id;
    },
    clearTimeout: id => timers.delete(id),
    canIUse(capability) {
      assert.equal(capability, 'SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask');
      return config.transient;
    }
  };
  const mocks = {
    '@kit.AbilityKit': {},
    '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 0 }, getUptime(type, nano) {
      assert.equal(type, 0); assert.equal(nano, false);
      if (config.clockError) throw Error('clock unavailable');
      return uptime;
    } } },
    '@kit.BackgroundTasksKit': { backgroundTaskManager },
    '@kit.NotificationKit': { notificationManager }
  };
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} };
    cache.set(file, module);
    const filename = path.join(sources, file + '.ets');
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: file + '.ts', compilerOptions, reportDiagnostics: true
    });
    assert.deepEqual(compiled.diagnostics || [], [], file + ' must transpile');
    vm.runInNewContext(compiled.outputText, { ...globals, module, exports: module.exports, require(name) {
      if (Object.hasOwn(mocks, name)) return mocks[name];
      assert.ok(name.startsWith('.'), 'Unexpected dependency: ' + name);
      return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)));
    } }, { filename });
    return module.exports;
  }
  const model = load('models/NotificationSyncTest');
  const Service = load('services/NotificationSyncTestService').NotificationSyncTestService;
  function createService(snapshots = []) {
    const service = new Service();
    service.observe(state => snapshots.push(normalize(state)));
    return service;
  }
  const service = createService(states);
  async function runDue() {
    let rounds = 0;
    while ([...timers.values()].some(timer => timer.due <= uptime)) {
      assert.ok(++rounds < 100, 'No spinning timers');
      const entry = [...timers].filter(([, timer]) => timer.due <= uptime).sort((a, b) => a[1].due - b[1].due)[0];
      timers.delete(entry[0]); entry[1].callback(); await flush();
    }
  }
  async function advance(duration) {
    const target = uptime + duration;
    let rounds = 0;
    while ([...timers.values()].some(timer => timer.due <= target)) {
      assert.ok(++rounds < 100, 'No spinning timers');
      const due = Math.min(...[...timers.values()].map(timer => timer.due));
      const delta = Math.max(0, due - uptime); wall += delta; uptime += delta;
      await runDue();
    }
    wall += target - uptime; uptime = target; await flush();
  }
  return { calls, config, model, service, states, context, globals, createService, advance, runDue, timers,
    test: delayed => service.test(context, delayed, () => true),
    async jump(duration) { uptime += duration; wall += duration; await flush(); },
    setUptime(value) { uptime = value; },
    async fireDelay(delay) {
      const entry = [...timers].find(([, timer]) => timer.delay === delay);
      assert.ok(entry, 'Expected timer ' + delay);
      timers.delete(entry[0]); entry[1].callback(); await flush();
    }
  };
}

let groups = 0;
async function check(name, run) {
  let watchdog;
  try {
    await Promise.race([run(), new Promise((resolve, reject) => {
      watchdog = setTimeout(() => reject(Error('Test hung: ' + name)), 5000);
    })]);
  } finally { clearTimeout(watchdog); }
  groups++;
  console.log('PASS: ' + name);
}

async function main() {
  await check('idle observation never requests permission, starts a task or publishes', async () => {
    const f = fixture(); await f.advance(120000);
    assert.equal(f.service.state().busy, false); assert.equal(f.service.state().scheduled, false);
    assert.deepEqual(f.calls, { queries: 0, permission: 0, slots: [], published: [], removed: [], tasks: [], released: [] });
  });

  await check('permission Promise success is not authorization and is rechecked', async () => {
    const f = fixture({ enabled: false }); await f.test(false);
    assert.equal(f.calls.permission, 1); assert.equal(f.calls.queries, 2);
    assert.equal(f.calls.slots.length, 0); assert.equal(f.calls.published.length, 0);
    assert.match(f.service.state().detail, /通知未开启/); assert.equal(f.service.state().busy, false);
  });

  await check('grant uses ability context then rechecks before publishing once', async () => {
    const f = fixture({ enabled: false, granted: true }); await f.test(false);
    assert.equal(f.calls.permission, 1); assert.equal(f.calls.queries, 3);
    assert.deepEqual(f.calls.slots, [2]); assert.equal(f.calls.published.length, 1);
    assert.ok(f.service.state().publishedAt > 0); assert.match(f.service.state().detail, /不代表腕上/);
  });

  await check('immediate request is an app-owned plain service notification with no real score', async () => {
    const f = fixture(); await f.test(false);
    const request = f.calls.published[0].request;
    assert.equal(request.id, f.model.NOTIFICATION_SYNC_TEST_ID);
    assert.equal(request.id, 29001); assert.equal(request.label, 'zuozhile-notification-sync-test');
    assert.equal(request.notificationSlotType, 2); assert.equal(request.content.notificationContentType, 0);
    assert.equal(request.content.normal.title, '坐直了 · 手环同步测试');
    assert.match(request.content.normal.text, /不计入守护记录/);
    assert.deepEqual(Object.keys(request).sort(), ['content', 'id', 'label', 'notificationSlotType']);
    assert.doesNotMatch(JSON.stringify(request), /randomId|client_id|baseline|frame|\d+分|QQ/);
    assert.equal(f.calls.tasks.length, 0);
  });

  await check('permission revoked after channel creation prevents submission', async () => {
    const f = fixture({ query: n => Promise.resolve(n === 1) }); await f.test(false);
    assert.equal(f.calls.queries, 2); assert.equal(f.calls.published.length, 0);
    assert.match(f.service.state().detail, /权限已关闭/);
  });

  await check('permission rejection and slot error stay local without retries', async () => {
    for (const config of [{ enabled: false, permission: () => Promise.reject({ code: 1600004 }) },
      { slot: () => Promise.reject({ code: 1600003 }) }]) {
      const f = fixture(config); await f.test(true); await f.advance(120000);
      assert.equal(f.calls.published.length, 0); assert.equal(f.calls.tasks.length, 0);
      assert.equal(f.service.state().busy, false);
    }
  });

  await check('double-click and simultaneous calls publish only one', async () => {
    const f = fixture(); await Promise.all([f.test(false), f.test(false), f.test(true)]);
    assert.equal(f.calls.published.length, 1); assert.deepEqual(f.calls.slots, [2]);
  });

  await check('in-flight slot is shared and observers recover across instances', async () => {
    const gate = deferred(), f = fixture({ publish: () => gate.promise }), otherStates = [];
    const other = f.createService(otherStates), running = f.test(false); await flush();
    assert.equal(other.state().busy, true); assert.equal(otherStates.at(-1).busy, true);
    await other.test(f.context, false, () => true); assert.equal(f.calls.published.length, 1);
    gate.resolve(); await running;
    assert.equal(other.state().busy, false); assert.equal(otherStates.at(-1).busy, false);
    assert.ok(other.state().cooldownRemainingMs > 0);
  });

  await check('cooldown survives reconstruction and clear without auto-send', async () => {
    const f = fixture(); await f.test(false); await f.service.clear();
    assert.deepEqual(f.calls.removed, [{ id: 29001, label: 'zuozhile-notification-sync-test' }]);
    assert.equal(f.service.state().cooldownRemainingMs, 60000);
    f.service.close(); const next = f.createService();
    await f.advance(59999); await next.test(f.context, false, () => true);
    assert.equal(f.calls.published.length, 1);
    await f.advance(2); assert.equal(f.calls.published.length, 1);
    await next.test(f.context, false, () => true); assert.equal(f.calls.published.length, 2);
  });

  await check('ten-second test publishes once and releases a valid zero task ID', async () => {
    const f = fixture(), running = f.test(true); await flush();
    assert.equal(f.service.state().scheduled, true); assert.equal(f.calls.tasks.length, 1);
    await f.advance(9999); assert.equal(f.calls.published.length, 0);
    await f.advance(1); await running;
    assert.equal(f.calls.published.length, 1); assert.equal(f.calls.published[0].uptime, 110000);
    assert.deepEqual(f.calls.released, [0]); assert.equal(f.service.state().scheduled, false);
    await f.advance(120000); assert.equal(f.calls.published.length, 1);
  });

  await check('unsupported, failed and insufficient tasks never silently fall back', async () => {
    for (const config of [{ transient: false }, { taskError: { code: 9900002 } }, { taskTime: 14999 }, { taskId: -1 }]) {
      const f = fixture(config); await f.test(true); await f.advance(120000);
      assert.equal(f.calls.published.length, 0); assert.equal(f.service.state().busy, false);
      if (config.taskTime) assert.deepEqual(f.calls.released, [0]);
    }
  });

  await check('cancel during delay releases task with no late resurrection', async () => {
    const f = fixture(), running = f.test(true); await flush(); f.service.cancel(); await running;
    await f.advance(120000); assert.equal(f.calls.published.length, 0);
    assert.deepEqual(f.calls.released, [0]); assert.equal(f.service.state().cooldownRemainingMs, 0);
    await f.test(false); assert.equal(f.calls.published.length, 1);
  });

  await check('system task expiry cancels pending notification instead of retrying', async () => {
    const f = fixture(), running = f.test(true); await flush();
    f.calls.tasks[0].expired(); await running; await f.advance(120000);
    assert.equal(f.calls.published.length, 0); assert.deepEqual(f.calls.released, [0]);
  });

  await check('page closure ignores late permission and detached observers', async () => {
    const gate = deferred(), f = fixture({ query: () => gate.promise });
    const running = f.test(false); await flush(); f.service.close();
    const snapshot = normalize(f.states); gate.resolve(true); await running; await f.advance(120000);
    assert.equal(f.calls.published.length, 0); assert.equal(f.calls.slots.length, 0);
    assert.deepEqual(f.states, snapshot);
    const next = f.createService(); assert.equal(next.state().busy, false);
  });

  await check('invalid runtime after query or delay cannot publish', async () => {
    for (const delayed of [false, true]) {
      const gate = deferred(), f = fixture(delayed ? {} : { query: () => gate.promise }); let allowed = true;
      const running = f.service.test(f.context, delayed, () => allowed); await flush(); allowed = false;
      if (delayed) await f.advance(10000); else gate.resolve(true);
      await running; assert.equal(f.calls.published.length, 0);
      assert.equal(f.service.state().busy, false);
    }
  });

  await check('query timeout drops late data with no automatic retry', async () => {
    const gate = deferred(), f = fixture({ query: () => gate.promise });
    const running = f.test(false); await flush(); await f.advance(5000); await running;
    assert.match(f.service.state().detail, /超时/); assert.equal(f.service.state().busy, false);
    gate.resolve(true); await f.advance(120000);
    assert.equal(f.calls.published.length, 0); assert.equal(f.calls.queries, 1);
  });

  await check('unanswered permission dialog times out and late approval cannot submit', async () => {
    const gate = deferred(), f = fixture({ enabled: false, permission: () => gate.promise });
    const running = f.test(true); await flush(); await f.advance(60000); await running;
    f.config.enabled = true; gate.resolve(); await flush(); await f.advance(120000);
    assert.equal(f.calls.published.length, 0); assert.equal(f.calls.tasks.length, 0);
  });

  await check('publish timeout blocks overlap until SDK settles and stays unknown', async () => {
    const gate = deferred(), f = fixture({ publish: () => gate.promise });
    const running = f.test(false); await flush(); await f.advance(5000); await running;
    assert.equal(f.service.state().busy, true); assert.equal(f.service.state().publishedAt, 0);
    const detail = f.service.state().detail; assert.match(detail, /结果未知/);
    await f.advance(60000); await f.test(false); await f.service.clear();
    assert.equal(f.calls.published.length, 1); assert.equal(f.calls.removed.length, 0);
    gate.resolve(); await flush(); assert.equal(f.service.state().busy, false);
    assert.equal(f.service.state().detail, detail); assert.equal(f.service.state().publishedAt, 0);
    f.config.publish = undefined; await f.test(false); assert.equal(f.calls.published.length, 2);
  });

  await check('clear timeout cannot erase a newer test through overlapping late cancellation', async () => {
    const f = fixture(); await f.test(false); const gate = deferred(); f.config.clear = () => gate.promise;
    const clearing = f.service.clear(); await flush(); await f.advance(5000); await clearing;
    assert.equal(f.service.state().busy, true); await f.advance(60000); await f.test(false);
    assert.equal(f.calls.published.length, 1); gate.resolve(); await flush();
    assert.equal(f.service.state().busy, false); await f.test(false);
    assert.equal(f.calls.published.length, 2); assert.equal(f.calls.removed.length, 1);
  });

  await check('sync and async SDK failures retain cooldown without retry', async () => {
    for (const code of [1600003, 1600005, 1600009]) {
      for (const sync of [true, false]) {
        const f = fixture({ publish: () => {
          if (sync) throw { code };
          return Promise.reject({ code });
        } });
        await f.test(false); assert.equal(f.service.state().busy, false);
        assert.equal(f.service.state().cooldownRemainingMs, 60000);
        await f.test(false); await f.advance(120000); assert.equal(f.calls.published.length, 1);
      }
    }
  });

  await check('suspended delay beyond TTL never flushes an obsolete test on resume', async () => {
    const f = fixture(), running = f.test(true); await flush();
    await f.jump(60000); await f.runDue(); await running;
    assert.equal(f.calls.published.length, 0); assert.deepEqual(f.calls.released, [0]);
    assert.match(f.service.state().detail, /过期|超时/);
  });

  await check('late query is bounded by uptime before a delayed timer callback', async () => {
    const gate = deferred(), f = fixture({ query: () => gate.promise });
    const running = f.test(false); await flush(); await f.jump(5001); gate.resolve(true); await running;
    assert.equal(f.calls.published.length, 0); assert.equal(f.calls.slots.length, 0);
    assert.match(f.service.state().detail, /过期/);
  });

  await check('monotonic rollback fails closed rather than sending early', async () => {
    const f = fixture(), running = f.test(true); await flush();
    f.setUptime(90000); await f.fireDelay(10000); await running;
    assert.equal(f.calls.published.length, 0); assert.equal(f.service.state().busy, false);
    assert.deepEqual(f.calls.released, [0]);
  });

  await check('missing notification and cleanup failure leave unrelated notifications alone', async () => {
    const f = fixture({ clear: () => Promise.reject({ code: 1600007 }) }); await f.service.clear();
    assert.match(f.service.state().detail, /没有该测试通知/);
    assert.deepEqual(f.calls.removed, [{ id: 29001, label: 'zuozhile-notification-sync-test' }]);
    const other = fixture({ releaseError: Error('cleanup failed') });
    const running = other.test(true); await flush(); other.service.cancel(); await running;
    assert.equal(other.service.state().busy, false); assert.equal(other.calls.published.length, 0);
  });

  await check('real panel requires foreground start but preserves explicit lock-screen delay', async () => {
    const f = fixture(), text = fs.readFileSync(path.join(sources, 'components/NotificationSyncTestPanel.ets'), 'utf8');
    const ast = ts.createSourceFile('Panel.ts', text.replaceAll('struct ', 'class '), ts.ScriptTarget.Latest, true);
    const panel = ast.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'NotificationSyncTestPanel');
    const names = ['send', 'canSend', 'availabilityChanged', 'aboutToDisappear'];
    const methods = names.map(name => {
      const member = panel.members.find(node => node.name?.getText(ast) === name);
      assert.ok(member, name); return member.getText(ast);
    });
    const subject = vm.runInNewContext(ts.transpileModule(`class Subject { ${methods.join('\n')} } new Subject();`,
      { compilerOptions }).outputText, { ...f.globals, NotificationSyncTestState: f.model.NotificationSyncTestState });
    const calls = [];
    Object.assign(subject, { active: true, foreground: true, locked: false,
      testState: new f.model.NotificationSyncTestState(), contextProvider: () => f.context,
      testAllowed: () => true, service: { test: (...args) => calls.push(args), cancel: () => calls.push('cancel'),
        close: () => calls.push('close') } });
    assert.equal(subject.canSend(), true); subject.send(true); assert.equal(calls.length, 1);
    const allowed = calls[0][2]; subject.foreground = false;
    assert.equal(allowed(), true); subject.send(false); assert.equal(calls.length, 1);
    subject.locked = true; assert.equal(allowed(), false); subject.testState.busy = true;
    subject.availabilityChanged(); assert.equal(calls.at(-1), 'cancel');
    subject.aboutToDisappear(); assert.equal(calls.at(-1), 'close');
  });

  await check('static boundaries keep Wear Engine, permissions, camera and statistics separate', async () => {
    const service = fs.readFileSync(path.join(sources, 'services/NotificationSyncTestService.ets'), 'utf8');
    const panel = fs.readFileSync(path.join(sources, 'components/NotificationSyncTestPanel.ets'), 'utf8');
    assert.doesNotMatch(service + panel, /@kit\.WearEngine|WearableReminderService|notificationManager\.cancelAll|client_id/);
    assert.doesNotMatch(service + panel, /SessionRecord|appendRecord|captureFrame|evaluatePosture|Preferences|persistData|startVibration/);
    const page = fs.readFileSync(path.join(sources, 'pages/Index.ets'), 'utf8');
    assert.equal((page.match(/NotificationSyncTestPanel\(\{/g) || []).length, 1);
    assert.match(page, /testAllowed: \(\): boolean => this\.loaded[\s\S]*?!this\.isSampling/);
    const manifest = fs.readFileSync(path.join(root, 'entry/src/main/module.json5'), 'utf8');
    assert.doesNotMatch(manifest, /client_id|NOTIFICATION_CONTROLLER|BLUETOOTH|HEALTH|PUBLISH_AGENT_REMINDER/);
  });
}

main().then(() => console.log('Notification sync offline regression passed: ' + groups + ' groups; no device calls.'))
  .catch(error => { console.error(error); process.exitCode = 1; });
