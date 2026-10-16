const assert = require('node:assert/strict');
const fs = require('node:fs');
const path = require('node:path');
const vm = require('node:vm');
const ts = require('./deveco-sdk.cjs').typescript;

const root = path.resolve(__dirname, '..');
const sourceRoot = path.join(root, 'entry/src/main/ets');
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
  let wall = Date.UTC(2026, 9, 15, 9), uptime = 100000, nextTimer = 0;
  const timers = new Map(), values = new Map(), order = [];
  const calls = { devices: 0, capabilities: 0, sends: [], on: 0, off: 0, destroy: 0, saved: 0,
    deviceClients: 0, notifyClients: 0, metadata: 0, abilities: [], enabled: 0, slots: 0,
    authorizations: [], addedSlots: [], publishes: [], active: {}, maxActive: {} };
  const config = { configured: true, supported: true, save: true, notificationSupported: true,
    notificationEnabled: true, slotEnabled: true, ...options };
  const death = new Set();
  class ClockDate extends Date { static now() { return wall; } }
  function native(name, action) {
    calls.active[name] = (calls.active[name] || 0) + 1;
    calls.maxActive[name] = Math.max(calls.maxActive[name] || 0, calls.active[name]);
    const done = () => { calls.active[name]--; };
    try {
      return Promise.resolve(action()).then(value => { done(); return value; }, error => { done(); throw error; });
    } catch (error) {
      done(); throw error;
    }
  }
  const device = (routeId, name = routeId, supported = true) => ({
    randomId: routeId, name, model: 'unit-test-model', softwareVersion: 'unit-test-firmware',
    isWearEngineCapabilitySupported(capability) {
      assert.equal(capability, 3);
      calls.capabilities++;
      return config.capability ? config.capability(routeId) : Promise.resolve(supported);
    }
  });
  config.devices = config.devices || [device('route-a', '离线设备A'), device('route-b', '离线设备B')];
  const sdk = {
    WearEngineCapability: { NOTIFICATION: 3 },
    NotificationType: { NOTIFICATION_WITH_ONE_BUTTON: 51 },
    ButtonId: { FIRST_BUTTON: 'firstButton' },
    getDeviceClient() {
      calls.deviceClients++;
      if (config.deviceClientError) throw config.deviceClientError;
      return { getConnectedDevices() {
        calls.devices++;
        return config.discovery ? config.discovery() : Promise.resolve(config.devices);
      } };
    },
    getNotifyClient() {
      calls.notifyClients++;
      if (config.notifyClientError) throw config.notifyClientError;
      return { notify(routeId, notification) {
        order.push('notify');
        calls.sends.push({ routeId, notification, at: wall, uptime });
        return native('send', () => config.send ? config.send() : undefined);
      } };
    },
    on(type, callback) {
      assert.equal(type, 'serviceDie'); calls.on++;
      if (config.listenError) throw config.listenError;
      death.add(callback);
    },
    off(type, callback) { assert.equal(type, 'serviceDie'); calls.off++; death.delete(callback); },
    destroy() { calls.destroy++; return config.close ? config.close() : Promise.resolve(); }
  };
  const notificationManager = {
    SlotType: { SERVICE_INFORMATION: 2 },
    SlotLevel: { LEVEL_NONE: 0, LEVEL_DEFAULT: 3, LEVEL_HIGH: 4 },
    ContentType: { NOTIFICATION_CONTENT_BASIC_TEXT: 0 },
    isNotificationEnabled() {
      calls.enabled++;
      return native('enabled', () => config.getEnabled ? config.getEnabled() : config.notificationEnabled);
    },
    getSlot(type) {
      assert.equal(type, 2); calls.slots++;
      return native('slot', () => config.getSlot ? config.getSlot() :
        { type, enabled: config.slotEnabled, notificationLevel: 4 });
    },
    requestEnableNotification(currentContext) {
      assert.equal(currentContext, context); calls.authorizations.push(currentContext);
      return native('authorization', () => config.authorize ? config.authorize() : undefined);
    },
    addSlot(type) {
      assert.equal(type, 2); calls.addedSlots.push(type);
      return native('addSlot', () => config.addSlot ? config.addSlot() : undefined);
    },
    publish(request) {
      order.push('publish'); calls.publishes.push({ request, at: wall, uptime });
      return native('publish', () => config.publish ? config.publish(request) : undefined);
    }
  };
  const store = {
    getSync: (key, fallback) => values.has(key) ? values.get(key) : fallback,
    get: async (key, fallback) => values.has(key) ? values.get(key) : fallback,
    putSync: (key, value) => { values.set(key, value); },
    put: async (key, value) => { values.set(key, value); },
    delete: async key => { values.delete(key); },
    flush: async () => {
      order.push('flush'); calls.saved++;
      if (!config.save) throw Error('storage unavailable');
      if (config.flush) await config.flush();
    }
  };
  const context = { currentHapModuleInfo: { get metadata() {
    calls.metadata++;
    return config.configured ? [{ name: 'client_id', value: 'offline-vm-only' }] : [];
  } } };
  const globals = {
    Date: ClockDate, Error, console,
    canIUse: capability => {
      calls.abilities.push(capability);
      if (capability === 'SystemCapability.Health.WearEngine') return config.supported;
      assert.equal(capability, 'SystemCapability.Notification.Notification'); return config.notificationSupported;
    },
    setTimeout: (callback, delay) => {
      const id = ++nextTimer; timers.set(id, { callback, due: uptime + delay }); return id;
    },
    clearTimeout: id => timers.delete(id)
  };
  const mocks = {
    '@kit.WearEngine': { wearEngine: sdk },
    '@kit.NotificationKit': { notificationManager },
    '@kit.BasicServicesKit': { systemDateTime: { TimeType: { STARTUP: 0 }, getUptime: (type, nano) => {
      assert.equal(type, 0); assert.equal(nano, false); return uptime;
    } } },
    '@kit.AbilityKit': {},
    '@kit.ArkData': { preferences: { getPreferences: async () => {
      if (config.preferences) return config.preferences();
      return store;
    } } }
  };
  const cache = new Map();
  function load(file) {
    if (cache.has(file)) return cache.get(file).exports;
    const module = { exports: {} }; cache.set(file, module);
    const filename = path.join(sourceRoot, file + '.ets');
    const compiled = ts.transpileModule(fs.readFileSync(filename, 'utf8'), {
      fileName: file + '.ts', compilerOptions, reportDiagnostics: true
    });
    assert.deepEqual(compiled.diagnostics || [], [], file + ' must transpile');
    vm.runInNewContext(compiled.outputText, {
      ...globals, module, exports: module.exports,
      require(name) {
        if (Object.hasOwn(mocks, name)) return mocks[name];
        assert.ok(name.startsWith('.'), 'Unexpected external dependency: ' + name);
        return load(path.posix.normalize(path.posix.join(path.posix.dirname(file), name)));
      }
    }, { filename });
    return module.exports;
  }
  const types = load('models/PostureTypes');
  const rules = load('models/LowScoreReminder');
  const model = load('models/WearableReminderPolicy');
  const channelModule = load('services/WearEngineNotificationChannel');
  const notificationModule = load('services/PhoneNotificationReminderChannel');
  const serviceModule = load('services/WearableReminderService');
  const storage = load('services/PostureSessionStore').PostureSessionStore;
  const policy = new model.WearableReminderPolicy();
  const clock = { wall: () => wall, uptime: () => uptime };
  const controller = new serviceModule.WearableReminderController(clock, policy);
  const channel = new channelModule.WearEngineNotificationChannel(context);
  const notificationChannel = new notificationModule.PhoneNotificationReminderChannel(context);
  const local = new model.WearableLocalState();
  controller.attach(channel, state => storage.saveWearable(context, state), local, notificationChannel);
  let runtime = new model.WearableRuntime();
  runtime.foreground = true; runtime.pageId = 1; runtime.sessionId = 1; runtime.testAllowed = true;
  controller.update(runtime);
  async function advance(duration, wallDuration = duration) {
    wall += wallDuration;
    uptime += duration;
    let rounds = 0;
    while ([...timers.values()].some(timer => timer.due <= uptime)) {
      assert.ok(++rounds < 100, 'Timers cannot spin indefinitely');
      for (const [id, timer] of [...timers]) {
        if (timer.due <= uptime) { timers.delete(id); timer.callback(); }
      }
      await flush();
    }
    await flush();
  }
  function update(patch = {}) {
    runtime = Object.assign(new model.WearableRuntime(), runtime, patch);
    controller.update(runtime);
    return runtime;
  }
  async function ready() {
    controller.setRoute(types.WearableReminderRoute.WEAR_ENGINE);
    controller.setEnabled(true);
    await controller.refresh();
    if (controller.state().devices.some(item => item.routeId === 'route-a')) controller.select('route-a');
    await flush();
  }
  async function readyNotification(prepare = true) {
    controller.setRoute(types.WearableReminderRoute.NOTIFICATION_SYNC);
    controller.setEnabled(true);
    if (prepare) await controller.prepareNotificationSync();
    else await controller.refresh();
    await flush();
  }
  function severe(score = 49, timestamp = wall) {
    update({ guarding: true, realSource: true, score, level: 3, expiresAt: wall + 7000, testAllowed: false });
    const decision = Object.assign(new rules.LowScoreDecision(), {
      level: 3, validSample: true, expiresAt: wall + 7000, alertType: types.PostureAlertType.ITEM_03
    });
    controller.submit(decision, score, timestamp);
    return decision;
  }
  return { load, config, calls, timers, values, order, context, store, globals, sdk, device, types, rules, model,
    channelModule, notificationModule, notificationManager, notificationChannel, serviceModule, controller, policy,
    clock, storage, local, channel, update, ready, readyNotification, severe, advance,
    now: () => wall, uptime: () => uptime,
    setClock(nextWall, nextUptime) { wall = nextWall; uptime = nextUptime; },
    die() { for (const callback of death) callback(); }
  };
}

function noWear(f, allowAReadiness = false) {
  for (const key of ['devices', 'capabilities', 'deviceClients', 'notifyClients', 'on', 'off', 'destroy']) {
    assert.equal(f.calls[key], 0, 'B must not use Wear Engine: ' + key);
  }
  assert.equal(f.calls.sends.length, 0);
  if (!allowAReadiness) {
    assert.equal(f.calls.metadata, 0, 'B readiness must not require a Wear client');
    assert.ok(!f.calls.abilities.includes('SystemCapability.Health.WearEngine'));
  }
}

function noNotificationMutation(f) {
  assert.equal(f.calls.authorizations.length, 0);
  assert.equal(f.calls.addedSlots.length, 0);
  assert.equal(f.calls.publishes.length, 0);
}

const pageSource = fs.readFileSync(path.join(sourceRoot, 'pages/Index.ets'), 'utf8');
const ast = ts.createSourceFile('Index.ts', pageSource.replaceAll('struct ', 'class '), ts.ScriptTarget.Latest, true);
const indexClass = ast.statements.find(node => ts.isClassDeclaration(node) && node.name.text === 'Index');
function pageMethod(name) {
  const member = indexClass.members.find(node => node.name?.getText(ast) === name);
  assert.ok(member, 'Missing real page method: ' + name);
  return member.getText(ast);
}

function pageFixture(options = {}) {
  const f = fixture(options);
  const calls = { records: 0, saved: 0, phone: 0, source: 0 };
  const names = ['captureFrame', 'lowScoreContext', 'applyLowScoreDecision', 'lowScoreLevelText',
    'dispatchLowScoreFeedback', 'markReminderFeedbackRecord', 'scheduleReminderExpiry', 'cancelReminderExpiry',
    'cancelBreakMessage', 'stopReminderFeedback', 'stopReminderPreview', 'stopLowScoreReminders',
    'resetReminderState', 'clearReminderDisplay', 'syncWearableRuntime', 'onWearableSettingsChanged',
    'onForegroundChanged', 'aboutToDisappear', 'isCurrentPageRun', 'controlsLocked'];
  const phoneCooldown = new f.rules.ReminderVibrationCooldown();
  const phone = {
    isAvailable: () => options.motor !== false,
    statusDetail: () => '本地马达桩', stop: () => {},
    pulsePair: async (current, started) => {
      if (!current() || options.motor === false) return false;
      calls.phone++; started(); return true;
    }
  };
  let pageOwner = 1;
  const facade = { controller: f.controller, isCurrentPage: pageId => pageId > 0 && pageId === pageOwner,
    destroy: async pageId => { if (pageId === pageOwner) { pageOwner = 0; await f.controller.close(); } } };
  const p = vm.runInNewContext(ts.transpileModule(`class Subject {
    ${names.map(pageMethod).join('\n')}
  } new Subject();`, { compilerOptions }).outputText, {
    ...f.globals, ...f.types, ...f.rules, ...f.model, WearableReminderService: facade,
    ReminderFeedbackService: phone, PHONE_VIBRATION_COOLDOWN: phoneCooldown,
    BREAK_MESSAGE_TIMEOUT_MS: 8000, evaluatePosture: sample => sample.result
  });
  Object.assign(p, { pageRunId: 1, guardRunId: 1, guardSessionStartedAt: f.now(), appForeground: true,
    wearablePageVisible: true, wearablePageId: 1, isGuarding: true, isSampling: false, isCalibrating: false,
    isStartingGuard: false, isStoppingGuard: false, isManualOperation: false, activeTab: 0,
    lowScoreLevel: 0, lowScoreDataValid: false, lowScoreExpiresAt: 0, lowScoreLatestScore: 100,
    reminderPreviewLevel: 0, reminderPreviewRunId: 0, reminderExpiryRunId: 0, breakMessageRunId: 0,
    reminderExpiryTimer: -1, breakMessageTimer: -1, records: [],
    reminderAction: f.types.ReminderAction.NONE, reminderAlertType: f.types.PostureAlertType.NONE,
    settings: f.types.createDefaultSettings(), lowScoreScheduler: new f.rules.LowScoreReminderScheduler(phoneCooldown),
    applyResult(result) { p.score = result.score; }, syncSourceStatus() {},
    persistData() { calls.saved++; },
    appendRecord(result) {
      calls.records++;
      p.records.unshift({ timestamp: result.timestamp, score: result.score, sitLevel: result.sit.level,
        chinLevel: result.chin.level, mouthLevel: result.mouth.level, action: result.action, alertType: result.primaryAlert });
    },
    stopGuard: async () => { p.isGuarding = false; },
    postureSource: { status: () => ({ isLive: true }), async sample() { calls.source++; return p.frame; } }
  });
  p.settings.wearableReminder = options.wearable !== false;
  p.settings.wearableReminderRoute = options.route || f.types.WearableReminderRoute.WEAR_ENGINE;
  p.settings.vibration = options.vibration !== false;
  p.settings.profile.sampleIntervalMs = options.interval || 3000;
  p.lowScoreScheduler.beginSession(1, f.now());
  p.onWearableSettingsChanged();
  function setFrame(score) {
    const metric = { level: f.types.PostureLevel.BAD, score, value: 35, baseline: 0, label: '低头',
      alertType: f.types.PostureAlertType.ITEM_03 };
    p.frame = { timestamp: f.now(), face: { confidence: .99, pitch: -35, roll: 0, yaw: 0,
      mouthAvailable: false, mouthOpenRatio: 0, rect: { left: 100, top: 80, width: 100, height: 120 } },
      skeleton: { nose: { x: 200, y: 120, score: .9 }, leftShoulder: { x: 100, y: 300, score: .9 },
        rightShoulder: { x: 300, y: 300, score: .9 } },
      reminderEvidence: { faceCount: 1, skeletonCount: 1, associationAmbiguous: false },
      result: { timestamp: f.now(), score, sit: metric, chin: metric,
        mouth: { ...metric, level: f.types.PostureLevel.UNKNOWN, alertType: f.types.PostureAlertType.NONE },
        summary: '', primaryAlert: f.types.PostureAlertType.ITEM_03, activeAlerts: [f.types.PostureAlertType.ITEM_03],
        action: f.types.ReminderAction.NONE } };
  }
  async function capture(score, elapsed = 0, patch = () => {}, force = false) {
    await f.advance(elapsed); setFrame(score); patch(p.frame);
    await p.captureFrame(force); await flush();
  }
  async function ready() {
    await f.controller.refresh();
    if (p.settings.wearableReminderRoute === f.types.WearableReminderRoute.WEAR_ENGINE) f.controller.select('route-a');
  }
  return { ...f, p, phone, phoneCooldown, pageCalls: calls, capture, setFrame, ready };
}

function startupFixture(options = {}) {
  const f = fixture(options);
  const service = f.serviceModule.WearableReminderService;
  const pageId = service.beginPage(), initialization = deferred(), settings = deferred();
  const bootCalls = { initializes: 0, reads: 0, statuses: [] };
  const data = f.types.createDefaultData();
  data.settings.wearableReminder = options.wearable !== false;
  data.settings.wearableReminderRoute = options.route || f.types.WearableReminderRoute.NOTIFICATION_SYNC;
  f.values.set('app_data', JSON.stringify(data));
  const get = f.store.get;
  f.store.get = async (key, fallback) => {
    assert.equal(key, 'app_data'); bootCalls.reads++;
    await settings.promise;
    return get(key, fallback);
  };
  const facade = { controller: service.controller, isCurrentPage: id => service.isCurrentPage(id),
    async initialize(context, id) {
      bootCalls.initializes++; await initialization.promise;
      await service.initialize(context, id);
    }
  };
  const names = ['initializeWearable', 'loadData', 'applyData', 'copySettings', 'onWearableSettingsChanged',
    'syncWearableRuntime', 'controlsLocked', 'isCurrentPageRun'];
  const p = vm.runInNewContext(ts.transpileModule(`class Subject {
    ${names.map(pageMethod).join('\n')}
  } new Subject();`, { compilerOptions }).outputText, {
    ...f.globals, ...f.types, ...f.model, WearableReminderService: facade, PostureSessionStore: f.storage
  });
  Object.assign(p, { pageRunId: 1, wearablePageId: pageId, wearablePageVisible: true, loaded: false,
    settings: f.types.createDefaultSettings(), records: [], appForeground: true, activeTab: 3,
    guardRunId: 1, isGuarding: false, isCalibrating: false, isStartingGuard: false, isStoppingGuard: false,
    isManualOperation: false, isSampling: false, lowScoreLatestScore: 100, lowScoreLevel: 0, lowScoreExpiresAt: 0,
    abilityContext: () => f.context, syncIdleSourceStatus() {},
    setStorageStatus(detail, healthy) { bootCalls.statuses.push({ detail, healthy }); },
    postureSource: { status: () => ({ isLive: true }) }
  });
  return { ...f, controller: service.controller, p, service, pageId, bootCalls, initialization, settings };
}

let checks = 0;
const failures = [];
async function check(name, run) {
  let watchdog;
  checks++;
  try {
    await Promise.race([run(), new Promise((resolve, reject) => {
      watchdog = setTimeout(() => reject(Error('Timed out: ' + name)), 5000);
    })]);
  } catch (error) {
    failures.push({ name, error });
    console.error('FAIL: ' + name); console.error(error);
    return;
  } finally { clearTimeout(watchdog); }
  console.log('PASS: ' + name);
}

async function main() {
  await check('default-off and missing client configuration never call Wear Engine', async () => {
    const f = fixture({ configured: false });
    f.controller.setRoute(f.types.WearableReminderRoute.WEAR_ENGINE);
    assert.equal(f.types.createDefaultSettings().wearableReminder, false);
    await f.controller.refresh(); await f.controller.test(); f.severe(); await flush();
    assert.equal(f.calls.devices, 0); assert.equal(f.calls.sends.length, 0); assert.equal(f.calls.on, 0);
    f.controller.setEnabled(true); await f.controller.refresh(); await f.controller.test();
    f.severe(); await flush();
    assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
    assert.equal(f.calls.devices, 0); assert.equal(f.calls.on, 0); assert.equal(f.calls.sends.length, 0);
    await assert.rejects(f.channel.discover(() => true), /Client ID/);
    assert.equal(f.calls.devices, 0);
  });

  await check('legacy settings migrate off without changing calibration or phone preferences', async () => {
    const f = fixture();
    const legacy = f.types.createDefaultSettings(); delete legacy.wearableReminder; delete legacy.wearableReminderRoute;
    legacy.vibration = false; legacy.lowScoreEdgeLight = false;
    f.values.set('app_data', JSON.stringify({ settings: legacy, records: [], lastUpdatedAt: f.now() }));
    const loaded = await f.storage.loadWithStatus(f.context);
    assert.equal(loaded.data.settings.wearableReminder, false);
    assert.equal(loaded.data.settings.wearableReminderRoute, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    assert.equal(loaded.data.settings.vibration, false); assert.equal(loaded.data.settings.lowScoreEdgeLight, false);
    assert.deepEqual(normalize(loaded.data.settings.profile), normalize(legacy.profile));
    loaded.data.settings.wearableReminder = true;
    assert.equal(await f.storage.save(f.context, loaded.data), true);
    assert.equal(JSON.parse(f.values.get('app_data')).settings.wearableReminder, true);
  });

  await check('explicit single-device selection, no automatic first target or broadcast', async () => {
    const f = fixture(); f.controller.setRoute(f.types.WearableReminderRoute.WEAR_ENGINE);
    f.controller.setEnabled(true); await f.controller.refresh();
    assert.equal(f.controller.state().status, f.model.WearableStatus.SELECT);
    await f.controller.test(); assert.equal(f.calls.sends.length, 0);
    f.controller.select('route-b'); await f.controller.test();
    assert.equal(f.calls.sends.length, 1); assert.equal(f.calls.sends[0].routeId, 'route-b');
    assert.equal(f.controller.state().confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
  });

  await check('unsupported phone or target stays local without fallback', async () => {
    const phone = fixture({ supported: false }); await phone.ready();
    assert.equal(phone.controller.state().status, phone.model.WearableStatus.UNSUPPORTED);
    assert.equal(phone.calls.devices, 0); assert.equal(phone.calls.on, 0);
    const target = fixture(); target.config.devices = [target.device('route-a', '不支持设备', false)];
    await target.ready(); await target.controller.test();
    assert.equal(target.controller.state().status, target.model.WearableStatus.UNSUPPORTED);
    assert.equal(target.calls.sends.length, 0);
    target.config.capability = () => Promise.reject(Object.assign(Error('unsupported'), { code: 801 }));
    await target.controller.refresh(); assert.equal(target.controller.state().devices[0].supported, false);
  });

  await check('real capture confirms severe at 2/3/5 seconds independent of phone vibration', async () => {
    for (const interval of [2000, 3000, 5000]) {
      const f = pageFixture({ interval, vibration: false, motor: false }); await f.ready();
      const started = f.now(); await f.capture(49);
      while (f.now() - started < 6000) {
        assert.equal(f.calls.sends.length, 0);
        await f.capture(49, interval);
      }
      assert.equal(f.calls.sends.length, 1, interval + 'ms confirmation');
      assert.equal(f.pageCalls.phone, 0); assert.equal(f.p.lowScoreLevel, 3);
      const notification = f.calls.sends[0].notification.notification;
      assert.match(notification.text, /49分.*请抬头/); assert.equal(notification.type, 51);
    }
  });

  await check('single sample, sub-six-second scores and refresh timers never send', async () => {
    const f = pageFixture(); await f.ready();
    await f.capture(49); await f.capture(49, 2000); await f.capture(49, 2000);
    assert.equal(f.calls.sends.length, 0); await f.advance(60000);
    assert.equal(f.calls.sends.length, 0); assert.equal(f.p.lowScoreLevel, 0);
    f.p.applyLowScoreDecision(f.p.lowScoreScheduler.refresh(f.p.lowScoreContext(), f.now()));
    assert.equal(f.calls.sends.length, 0);
  });

  await check('51-point severe hysteresis cannot repeat until a new under-50 sample', async () => {
    const f = pageFixture({ vibration: false }); await f.ready();
    await f.capture(49); await f.capture(49, 3000); await f.capture(49, 3000);
    for (let i = 0; i < 20; i++) await f.capture(51, 3000);
    assert.equal(f.p.lowScoreLevel, 3); assert.equal(f.calls.sends.length, 1);
    await f.capture(49, 3000); assert.equal(f.calls.sends.length, 2);
    const samples = f.pageCalls.source, sends = f.calls.sends.length;
    f.controller.submit(Object.assign(new f.rules.LowScoreDecision(), {
      level: 3, validSample: true, expiresAt: f.now() + 7000
    }), 49, f.p.frame.timestamp);
    await f.advance(60000);
    assert.equal(f.calls.sends.length, sends); assert.equal(f.pageCalls.source, samples);
  });

  await check('49/51 oscillation never confirms a new severe episode', async () => {
    const f = pageFixture(); await f.ready();
    for (let i = 0; i < 30; i++) await f.capture(i % 2 ? 51 : 49, i ? 3000 : 0);
    assert.equal(f.calls.sends.length, 0);
  });

  await check('phone and wrist cooldowns do not consume or reset each other', async () => {
    const f = pageFixture(); await f.ready();
    f.phoneCooldown.claim(f.now());
    await f.capture(49); await f.capture(49, 3000); await f.capture(49, 3000);
    assert.equal(f.calls.sends.length, 1); assert.equal(f.pageCalls.phone, 0);
    for (let i = 0; i < 18; i++) await f.capture(49, 3000);
    assert.equal(f.pageCalls.phone, 1); assert.equal(f.calls.sends.length, 5);
    await f.capture(49, 6000); assert.equal(f.calls.sends.length, 6);
  });

  await check('phone and wrist do not double-count business reminders', async () => {
    const enabled = pageFixture(), disabled = pageFixture({ wearable: false });
    await enabled.ready();
    for (let i = 0; i < 24; i++) {
      await enabled.capture(49, i ? 3000 : 0);
      await disabled.capture(49, i ? 3000 : 0);
    }
    assert.equal(enabled.calls.sends.length, 6); assert.equal(disabled.calls.sends.length, 0);
    assert.deepEqual(normalize(enabled.p.records), normalize(disabled.p.records));
    assert.equal(enabled.pageCalls.phone, disabled.pageCalls.phone);
    const snapshot = normalize(enabled.p.records), saves = enabled.pageCalls.saved;
    enabled.calls.sends[0].notification.onAction({ action: 2 }); await flush();
    assert.deepEqual(normalize(enabled.p.records), snapshot); assert.equal(enabled.pageCalls.saved, saves);
  });

  await check('invalid evidence, mock, manual, calibration and background never send', async () => {
    for (const patch of [frame => { delete frame.skeleton.leftShoulder; },
      frame => { frame.reminderEvidence.faceCount = 2; }, frame => { frame.face.confidence = 0; },
      frame => { frame.reminderEvidence.associationAmbiguous = true; }]) {
      const f = pageFixture(); await f.ready();
      await f.capture(49, 0, patch); await f.capture(49, 3000, patch); await f.capture(49, 3000, patch);
      assert.equal(f.calls.sends.length, 0);
    }
    for (const patch of [{ isGuarding: false }, { isCalibrating: true }, { appForeground: false }]) {
      const f = pageFixture(); await f.ready(); Object.assign(f.p, patch);
      await f.capture(49, 0, () => {}, true); await f.capture(49, 6000, () => {}, true);
      assert.equal(f.calls.sends.length, 0);
    }
    const mock = pageFixture(); await mock.ready(); mock.p.settings.useCoreVision = false;
    await mock.capture(49); await mock.capture(49, 6000); assert.equal(mock.calls.sends.length, 0);
  });

  await check('candidate identity, finite values, deduplication and min-five-second TTL', async () => {
    const f = fixture();
    const runtime = f.update({ guarding: true, realSource: true, score: 49, level: 3, expiresAt: f.now() + 11000 });
    const decision = Object.assign(new f.rules.LowScoreDecision(), {
      level: 3, validSample: true, expiresAt: f.now() + 11000, alertType: f.types.PostureAlertType.ITEM_03
    });
    const create = (d = decision, score = 49, timestamp = f.now(), r = runtime) =>
      f.policy.create(d, score, timestamp, r, 7, f.now(), f.uptime());
    for (const score of [-1, 50, 51, Infinity, NaN]) assert.equal(create(decision, score), undefined);
    for (const expiresAt of [NaN, Infinity, f.now() - 1]) {
      assert.equal(create({ ...decision, expiresAt }), undefined);
    }
    assert.equal(create(decision, 49, f.now() + 1), undefined);
    assert.equal(create(decision, 49, -1), undefined);
    assert.equal(create({ ...decision, validSample: false }), undefined);
    const candidate = create();
    assert.ok(candidate); assert.equal(candidate.expiresAt, f.now() + 5000);
    assert.equal(candidate.deadlineUptime, f.uptime() + 5000);
    assert.equal(candidate.generation, 7); assert.equal(candidate.sampleTimestamp, f.now());
    assert.equal(create(), undefined);
    await f.advance(1);
    const next = create({ ...decision, expiresAt: f.now() + 100 });
    assert.notEqual(next.eventId, candidate.eventId); assert.equal(next.deadlineUptime, f.uptime() + 100);
  });

  await check('double-click test sends one and shares cooldown with formal events across switches', async () => {
    const f = fixture(); await f.ready();
    await Promise.all([f.controller.test(), f.controller.test()]);
    assert.equal(f.calls.sends.length, 1); assert.equal(f.controller.state().canTest, false);
    assert.equal(f.calls.sends[0].notification.notification.title, '腕上提醒测试');
    f.controller.setEnabled(false); f.controller.setEnabled(true); await f.controller.refresh();
    f.controller.select('route-b'); f.severe(); await flush();
    assert.equal(f.calls.sends.length, 1);
    f.update({ pageId: 2, sessionId: 2 }); f.severe(); await flush();
    assert.equal(f.calls.sends.length, 1);
    await f.advance(9999); f.severe(); await flush(); assert.equal(f.calls.sends.length, 1);
    assert.equal(f.controller.state().cooldownRemainingMs, 1);
    await f.advance(1); assert.equal(f.calls.sends.length, 1, 'Cooldown timer cannot send an event');
    assert.equal(f.controller.state().cooldownRemainingMs, 0);
    f.severe(); await flush(); assert.equal(f.calls.sends.length, 2);
    assert.equal(f.calls.sends[1].routeId, 'route-b');
    f.update({ guarding: false, testAllowed: true });
    await f.controller.test(); assert.equal(f.calls.sends.length, 2);
  });

  await check('query continuations recheck every cancellation boundary before notify', async () => {
    const cancellations = [f => f.controller.setEnabled(false), f => f.update({ foreground: false }),
      f => f.update({ calibrating: true }), f => f.update({ pageId: 2 }), f => f.update({ sessionId: 2 }),
      f => f.update({ guarding: false }), f => f.update({ realSource: false }),
      f => f.update({ score: 51 }), f => f.update({ expiresAt: 0 }),
      f => f.controller.select('route-b'), f => f.die(), f => f.controller.close()];
    for (const cancel of cancellations) {
      const f = fixture(); await f.ready(); const gate = deferred();
      f.config.discovery = () => gate.promise;
      f.severe(); await flush();
      cancel(f); gate.resolve(f.config.devices); await flush();
      assert.equal(f.calls.sends.length, 0, cancel.toString());
      assert.notEqual(f.controller.state().status, f.model.WearableStatus.CHECKING,
        'Cancelled operation must not leave the settings status stuck at checking');
      f.config.discovery = undefined; await f.advance(60001);
      assert.equal(f.calls.sends.length, 0, 'No backlog on recovery');
    }
  });

  await check('query and capability timeout expire operation, ignore late data and do not hang UI', async () => {
    for (const phase of ['discovery', 'capability']) {
      const f = fixture(); await f.ready(); const gate = deferred();
      if (phase === 'discovery') f.config.discovery = () => gate.promise;
      else f.config.capability = () => gate.promise;
      f.severe(); await flush(); const queries = f.calls.capabilities;
      await f.advance(5000);
      assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
      assert.equal(f.controller.state().busy, false);
      gate.resolve(phase === 'discovery' ? f.config.devices : true); await flush();
      assert.equal(f.calls.sends.length, 0);
      if (phase === 'capability') assert.equal(f.calls.capabilities, queries, 'No next device query after timeout');
    }
  });

  await check('freshness uses monotonic TTL despite wall-clock shifts', async () => {
    for (const wallDuration of [-1000, 3600000]) {
      const f = fixture(); await f.ready(); const gate = deferred();
      f.config.discovery = () => gate.promise;
      f.severe(); await flush(); await f.advance(5000, wallDuration);
      gate.resolve(f.config.devices); await flush(); assert.equal(f.calls.sends.length, 0);
    }
  });

  await check('reconnected random route requires explicit reselection and never sends to old ID', async () => {
    const f = fixture(); await f.ready();
    f.config.devices = [f.device('route-new', '离线设备A')];
    f.severe(); await flush();
    assert.equal(f.calls.sends.length, 0); assert.equal(f.controller.state().selectedId, '');
    f.controller.select('route-new'); await f.advance(1); f.severe(); await flush();
    assert.equal(f.calls.sends.length, 1); assert.equal(f.calls.sends[0].routeId, 'route-new');
    const unsupported = fixture(); await unsupported.ready();
    unsupported.config.devices = [unsupported.device('route-a', '同一设备', false)];
    unsupported.severe(); await flush(); assert.equal(unsupported.calls.sends.length, 0);
    assert.equal(unsupported.controller.state().status, unsupported.model.WearableStatus.UNSUPPORTED);
  });

  await check('cooldown is durable before notify, save failure cancels and does not retry', async () => {
    const f = fixture(); await f.ready(); f.severe(); await flush();
    assert.ok(f.order.indexOf('flush') >= 0); assert.ok(f.order.indexOf('flush') < f.order.indexOf('notify'));
    const failed = fixture({ save: false }); await failed.ready(); failed.severe(); await flush();
    assert.equal(failed.calls.sends.length, 0); assert.equal(failed.controller.state().storageHealthy, false);
    assert.equal(failed.controller.state().status, failed.model.WearableStatus.FAILED);
    failed.config.save = true; await failed.advance(1); failed.severe(); await flush();
    assert.equal(failed.calls.sends.length, 0);
    await failed.advance(9999); assert.equal(failed.calls.sends.length, 0);
    await failed.ready();
    failed.severe(); await flush(); assert.equal(failed.calls.sends.length, 1);
  });

  await check('save-in-flight cancellation and timeout cannot submit after late flush', async () => {
    for (const cancel of [f => f.controller.setEnabled(false), f => f.advance(5000)]) {
      const f = fixture(); await f.ready(); const gate = deferred();
      f.config.flush = () => gate.promise;
      f.severe(); await flush(); assert.equal(f.calls.saved, 1); assert.equal(f.calls.sends.length, 0);
      await cancel(f); gate.resolve(); await flush(); assert.equal(f.calls.sends.length, 0);
    }
  });

  await check('SDK send timeout stays unknown, does not overlap, and late resolve cannot replay', async () => {
    const f = fixture(); await f.ready(); const gate = deferred(); f.config.send = () => gate.promise;
    const testing = f.controller.test(); await flush(); assert.equal(f.calls.sends.length, 1);
    await f.advance(5000); await testing;
    assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
    assert.equal(f.controller.state().busy, true); assert.match(f.controller.state().testResult, /结果未知/);
    assert.equal(f.controller.state().canConfirmTest, true);
    f.controller.confirm(f.model.WearableTestConfirmation.DISPLAYED); await flush();
    assert.equal(f.controller.state().confirmation, f.model.WearableTestConfirmation.DISPLAYED);
    await f.advance(5000); assert.equal(f.controller.state().cooldownRemainingMs, 0);
    await f.controller.test(); f.severe(); await flush();
    assert.equal(f.controller.state().busy, true);
    assert.equal(f.calls.sends.length, 1);
    gate.resolve(); await flush(); assert.equal(f.calls.sends.length, 1);
    assert.match(f.controller.state().testResult, /结果未知/, 'Late Promise resolve cannot claim receipt');
    f.config.send = undefined; await f.ready(); await f.advance(1); f.severe(); await flush();
    assert.equal(f.calls.sends.length, 2);
  });

  await check('synchronous and async SDK errors map correctly and leave phone flow intact', async () => {
    for (const code of [401, 801, 1008500001, 1008500002, 1008500003, 1008500004, 1008500005,
      1008500006, 1008500007, 1008500008, 1008500009, 1008500010, 1008509999]) {
      const f = fixture(); await f.ready();
      f.config.send = () => Promise.reject(Object.assign(Error('sdk-failed'), { code }));
      await f.controller.test();
      assert.equal(f.calls.sends.length, 1); assert.equal(f.controller.state().busy, false);
      assert.ok(f.controller.state().detail.includes(code.toString()));
      await f.controller.test(); assert.equal(f.calls.sends.length, 1);
    }
    const sync = fixture(); sync.config.deviceClientError = Object.assign(Error('sync'), { code: 1008500004 });
    sync.controller.setRoute(sync.types.WearableReminderRoute.WEAR_ENGINE);
    sync.controller.setEnabled(true); await sync.controller.refresh();
    assert.equal(sync.controller.state().status, sync.model.WearableStatus.CONFIGURATION);
    const sendSync = fixture(); await sendSync.ready();
    sendSync.config.notifyClientError = Object.assign(Error('sync'), { code: 1008500010 });
    await sendSync.controller.test(); assert.equal(sendSync.controller.state().busy, false);
    assert.equal(sendSync.controller.state().status, sendSync.model.WearableStatus.DISCONNECTED);
  });

  await check('API success, action zero, errors and user confirmation stay independent', async () => {
    const f = fixture(); await f.ready(); await f.controller.test();
    const state = f.controller.state();
    assert.match(state.testResult, /发送请求成功/); assert.match(state.testResult, /未确认/);
    assert.equal(state.confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
    const feedback = f.calls.sends[0].notification.onAction;
    feedback({ action: 0 }); await flush();
    assert.equal(f.controller.state().diagnostics[0].action, 0);
    assert.match(f.controller.state().testFeedback, /转入后台/);
    assert.equal(f.controller.state().confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
    for (const result of [f.model.WearableTestConfirmation.VIBRATED, f.model.WearableTestConfirmation.DISPLAYED,
      f.model.WearableTestConfirmation.NOT_RECEIVED]) {
      f.controller.confirm(result); await flush(); assert.equal(f.controller.state().confirmation, result);
      const loaded = await f.storage.loadWearable(f.context); assert.equal(loaded.confirmation, result);
    }
    feedback({ errorCode: 255 }); await flush();
    assert.equal(f.controller.state().diagnostics[0].feedbackErrorCode, 255);
    assert.equal(f.controller.state().diagnostics[0].errorCode, 0);
    assert.match(f.controller.state().testFeedback, /回调错误/);
    assert.equal(f.controller.state().confirmation, f.model.WearableTestConfirmation.NOT_RECEIVED);
  });

  await check('cleared diagnostics cannot be resurrected by old send or action callbacks', async () => {
    const f = fixture(); await f.ready(); const gate = deferred(); f.config.send = () => gate.promise;
    const testing = f.controller.test(); await flush();
    const feedback = f.calls.sends[0].notification.onAction;
    f.controller.clearDiagnostics(); feedback({ action: 0 }); gate.resolve(); await testing; await flush();
    const state = f.controller.state();
    assert.equal(state.testAt, 0); assert.equal(state.diagnosticCount, 0);
    assert.ok(state.cooldownRemainingMs > 0, 'Clearing diagnostics cannot bypass cooldown');
    assert.equal((await f.storage.loadWearable(f.context)).testAt, 0);
  });

  await check('old callbacks cannot rewrite a newer test or revive a closed page', async () => {
    const f = fixture(); await f.ready(); await f.controller.test();
    const old = f.calls.sends[0].notification.onAction;
    await f.advance(10001); await f.controller.test();
    f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED); await flush();
    const latest = normalize(f.controller.state()); old({ action: 1 }); await flush();
    assert.equal(f.controller.state().testAt, latest.testAt);
    assert.equal(f.controller.state().testFeedback, latest.testFeedback);
    assert.equal(f.controller.state().confirmation, latest.confirmation);
    await f.controller.close(); old({ action: 2 }); await flush();
    assert.equal(f.controller.state().status, f.model.WearableStatus.OFF);
    assert.equal(f.controller.state().selectedId, ''); assert.equal(f.calls.sends.length, 2);
    assert.equal(f.calls.off, 1); assert.equal(f.calls.destroy, 1);
  });

  await check('send slot and cooldown survive page reconstruction without stale selections', async () => {
    const f = fixture(); await f.ready(); const gate = deferred(); f.config.send = () => gate.promise;
    const testing = f.controller.test(); await flush();
    await f.controller.close(); await testing;
    const restored = await f.storage.loadWearable(f.context);
    f.controller.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
      state => f.storage.saveWearable(f.context, state), restored);
    f.update({ pageId: 2, foreground: true, guarding: false, testAllowed: true });
    f.controller.setEnabled(true); await f.controller.refresh();
    assert.equal(f.controller.state().selectedId, ''); assert.equal(f.controller.state().busy, true);
    await f.advance(10000); await f.controller.test(); assert.equal(f.calls.sends.length, 1);
    assert.equal(f.controller.state().cooldownRemainingMs, 0); assert.equal(f.controller.state().busy, true);
    gate.resolve(); await flush();
    await f.controller.refresh(); f.controller.select('route-a'); f.config.send = undefined;
    await f.controller.test(); assert.equal(f.calls.sends.length, 2);
  });

  await check('closed channel service-death callbacks cannot invalidate a reconstructed page', async () => {
    const f = fixture(); let oldDeath;
    const on = f.sdk.on;
    f.sdk.on = (type, callback) => { oldDeath = callback; on(type, callback); };
    await f.ready(); const callback = oldDeath;
    await f.controller.close();
    f.controller.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
      state => f.storage.saveWearable(f.context, state), new f.model.WearableLocalState());
    f.update({ pageId: 2, foreground: true, testAllowed: true }); await f.ready();
    callback(); assert.equal(f.controller.state().selectedId, 'route-a');
    await f.controller.test(); assert.equal(f.calls.sends.length, 1);
  });

  await check('real page cancels pending wrist requests on invalid sample, background and disposal', async () => {
    for (const cancel of [async f => f.capture(49, 1, frame => { delete frame.skeleton.nose; }),
      async f => { f.p.appForeground = false; f.p.onForegroundChanged(); },
      async f => f.p.aboutToDisappear()]) {
      const f = pageFixture(); await f.ready(); const gate = deferred();
      await f.capture(49); await f.capture(49, 3000);
      f.config.discovery = () => gate.promise;
      await f.capture(49, 3000); assert.equal(f.calls.sends.length, 0);
      await cancel(f); gate.resolve(f.config.devices); await flush();
      assert.equal(f.calls.sends.length, 0); assert.equal(f.p.lowScoreDataValid, false);
    }
  });

  await check('switching formal guard tabs does not cancel a current severe candidate', async () => {
    const f = pageFixture(); f.p.activeTab = 3; await f.ready();
    await f.capture(49); await f.capture(49, 3000);
    const gate = deferred(); f.config.discovery = () => gate.promise;
    await f.capture(49, 3000);
    f.p.activeTab = 2; f.p.syncWearableRuntime(); gate.resolve(f.config.devices); await flush();
    assert.equal(f.calls.sends.length, 1);
  });

  await check('test navigation and calibration cancellation cannot deliver after async capability return', async () => {
    for (const patch of [{ testAllowed: false }, { calibrating: true }, { guarding: true }, { foreground: false }]) {
      const f = fixture(); await f.ready(); const gate = deferred();
      f.config.capability = () => gate.promise;
      const testing = f.controller.test(); await flush();
      f.update(patch); gate.resolve(true); await testing; await flush();
      assert.equal(f.calls.sends.length, 0);
    }
  });

  await check('page leases are unique and stale page teardown cannot overwrite or close the new owner', async () => {
    const f = fixture(); const service = f.serviceModule.WearableReminderService;
    const firstPage = service.beginPage();
    await service.initialize(f.context, firstPage);
    const controller = service.controller;
    controller.setRoute(f.types.WearableReminderRoute.WEAR_ENGINE);
    const runtime = Object.assign(new f.model.WearableRuntime(), {
      pageId: firstPage, sessionId: 1, foreground: true, testAllowed: true
    });
    controller.update(runtime); controller.setEnabled(true); await controller.refresh(); controller.select('route-a');
    await controller.test(); assert.equal(f.calls.sends.length, 1);
    const secondPage = service.beginPage(); assert.notEqual(firstPage, secondPage);
    await service.initialize(f.context, secondPage);
    controller.update(Object.assign(new f.model.WearableRuntime(), {
      pageId: secondPage, sessionId: 1, foreground: true, testAllowed: true
    }));
    controller.setEnabled(true); await controller.refresh(); controller.select('route-a');
    await service.destroy(firstPage); assert.equal(service.isCurrentPage(secondPage), true);
    assert.equal(controller.state().selectedId, 'route-a');
    assert.ok(controller.state().cooldownRemainingMs > 0);
    const oldPage = pageFixture();
    const oldState = normalize(oldPage.controller.state());
    oldPage.p.wearablePageId = 999; oldPage.p.settings.wearableReminder = false;
    oldPage.p.onWearableSettingsChanged(); oldPage.p.syncWearableRuntime();
    assert.deepEqual(normalize(oldPage.controller.state()), oldState);
    await service.destroy(secondPage);
  });

  await check('storage is bounded, excludes random route and payload, and serializes snapshots', async () => {
    const f = fixture(); const gate = deferred(); let index = 0;
    f.config.flush = () => ++index === 1 ? gate.promise : Promise.resolve();
    const local = new f.model.WearableLocalState(); local.testAt = f.now(); local.testResult = 'first';
    const first = f.storage.saveWearable(f.context, local); local.testResult = 'second';
    const second = f.storage.saveWearable(f.context, local); local.testResult = 'mutated';
    await flush(); assert.equal(f.calls.saved, 1); gate.resolve(); await first; await second;
    assert.equal(f.values.get('wearable_local_test_result'), 'second');
    assert.ok([...f.values.keys()].every(key => key.startsWith('wearable_local_')));
    assert.doesNotMatch(JSON.stringify([...f.values]), /randomId|route-a|frame|baseline|account|知道了/);
    const active = fixture(); await active.ready(); await active.controller.test();
    const saved = JSON.stringify([...active.values]);
    assert.doesNotMatch(saved, /route-a|route-b|randomId|知道了|不计入守护记录/);
    assert.ok(Buffer.byteLength(active.values.get('wearable_local_test_result')) <= 120);
  });

  await check('diagnostic retention is at most 100 entries and 24 hours, no late resurrection', async () => {
    const f = fixture(); await f.ready();
    for (let i = 0; i < 102; i++) {
      if (i) await f.advance(10001);
      await f.controller.test();
    }
    assert.equal(f.controller.state().diagnosticCount, 100);
    const feedback = f.calls.sends.at(-1).notification.onAction;
    await f.advance(86400001);
    assert.equal(f.controller.state().diagnosticCount, 0); assert.equal(f.controller.state().testAt, 0);
    feedback({ action: 2 }); await flush();
    assert.equal(f.controller.state().diagnosticCount, 0);
    assert.equal((await f.storage.loadWearable(f.context)).testAt, 0);
  });

  await check('restart restores remaining cooldown while abnormal clocks wait at most 10 seconds', async () => {
    const f = fixture(); const policy = new f.model.WearableReminderPolicy();
    assert.equal(f.model.WEARABLE_COOLDOWN_MS, 10000);
    assert.equal(policy.claim(f.uptime()), true);
    policy.restore(f.now(), f.uptime(), f.now() + 5000, f.uptime() + 5000);
    assert.equal(policy.remaining(f.uptime() + 5000), 5000);
    assert.equal(policy.remaining(f.uptime() + 9999), 1);
    assert.equal(policy.remaining(f.uptime() + 10000), 0);
    for (const input of [[f.now() + 1000, f.uptime()], [f.now(), f.uptime() + 1000],
      [NaN, NaN], [-1, -1], [f.now(), Number.MAX_SAFE_INTEGER]]) {
      const restored = new f.model.WearableReminderPolicy();
      restored.restore(input[0], input[1], f.now(), f.uptime());
      assert.equal(restored.remaining(f.uptime()), 10000);
      assert.equal(restored.remaining(f.uptime() + 9999), 1);
      assert.equal(restored.remaining(f.uptime() + 10000), 0);
    }
    const reboot = new f.model.WearableReminderPolicy(); reboot.claim(1000000);
    reboot.restore(f.now(), 1000000, f.now() + 1000, 100);
    assert.equal(reboot.remaining(100), 10000); assert.equal(reboot.remaining(10100), 0);
    const forward = new f.model.WearableReminderPolicy();
    forward.restore(f.now(), f.uptime(), f.now() + 3600000, f.uptime() + 5000);
    assert.equal(forward.remaining(f.uptime() + 5000), 5000);
    assert.equal(forward.remaining(f.uptime() + 10000), 0);
    const corrupt = fixture(); corrupt.values.set('wearable_local_attempt', 'bad');
    corrupt.values.set('wearable_local_uptime', 'bad');
    const local = await corrupt.storage.loadWearable(corrupt.context);
    const safe = new corrupt.model.WearableReminderPolicy();
    safe.restore(local.lastAttemptAt, local.lastAttemptUptime, corrupt.now(), corrupt.uptime());
    assert.equal(safe.remaining(corrupt.uptime()), 10000);
    assert.equal(safe.remaining(corrupt.uptime() + 10000), 0);
    const repeated = new f.model.WearableReminderPolicy();
    repeated.restore(f.now() + 3600000, Number.MAX_SAFE_INTEGER, f.now(), f.uptime());
    repeated.restore(f.now() + 3600000, Number.MAX_SAFE_INTEGER, f.now() + 5000, f.uptime() + 5000);
    assert.equal(repeated.remaining(f.uptime() + 5000), 5000);
    repeated.restore(f.now() + 3600000, Number.MAX_SAFE_INTEGER, f.now() + 10000, f.uptime() + 10000);
    assert.equal(repeated.remaining(f.uptime() + 10000), 0, 'Reconstruction must not perpetually extend corrupt data');
  });

  await check('UTF-8 limits preserve code points and template has minimal notification-only data', async () => {
    const f = fixture();
    for (const max of [0, 1, 2, 3, 4, 11, 27, 399]) {
      for (const text of ['abc', '请调整坐姿'.repeat(100), '\u{20000}'.repeat(100), 'a中\u{1F642}z']) {
        const bounded = f.model.wearableUtf8(text, max);
        assert.ok(Buffer.byteLength(bounded, 'utf8') <= max); assert.ok(text.startsWith(bounded));
        assert.equal(Buffer.from(bounded).toString(), bounded);
      }
    }
    await f.ready(); await f.controller.test();
    const notification = f.calls.sends[0].notification.notification;
    assert.equal(notification.bundleName, '坐直了'); assert.ok(Buffer.byteLength(notification.title) < 28);
    assert.ok(Buffer.byteLength(notification.text) < 400);
    assert.ok(Buffer.byteLength(notification.buttons[0].content) < 12);
    assert.deepEqual(Object.keys(notification).sort(), ['bundleName', 'buttons', 'text', 'title', 'type']);
  });

  await check('route defaults to B while off without preparing, publishing or enabling reminders', async () => {
    const f = fixture({ configured: false });
    const defaults = f.types.createDefaultSettings();
    assert.equal(defaults.wearableReminder, false);
    assert.equal(defaults.wearableReminderRoute, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    assert.equal(f.controller.state().route, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    f.controller.setRoute(f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    await f.controller.refresh(); await f.controller.prepareNotificationSync(); await f.controller.test();
    f.severe(); await flush();
    assert.equal(f.controller.state().route, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    assert.equal(f.controller.state().status, f.model.WearableStatus.OFF);
    assert.equal(f.calls.enabled, 0); assert.equal(f.calls.slots, 0);
    assert.equal(f.calls.saved, 0); noNotificationMutation(f); noWear(f);
    f.controller.setEnabled(true);
    assert.equal(f.calls.enabled, 0); noNotificationMutation(f);
    f.controller.setRoute('invalid-route');
    assert.equal(f.controller.state().route, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    assert.equal(f.calls.publishes.length, 0);
  });

  await check('A configuration, device and SDK failures never query or fall back to phone notifications', async () => {
    const scenarios = [{ configured: false }, { supported: false }, { devices: [] },
      { discovery: () => Promise.reject(Object.assign(Error('query failed'), { code: 1008500004 })) },
      { send: () => Promise.reject(Object.assign(Error('send failed'), { code: 1008500010 })) }, {}];
    for (const options of scenarios) {
      const f = fixture(options); await f.ready(); await f.controller.test(); f.severe(); await flush();
      await f.controller.prepareNotificationSync(); await f.advance(60001);
      assert.equal(f.calls.enabled, 0); assert.equal(f.calls.slots, 0); noNotificationMutation(f);
      assert.ok(!f.calls.abilities.includes('SystemCapability.Notification.Notification'));
    }
  });

  await check('missing and malformed routes default to B while explicit A or B stays unchanged', async () => {
    const f = fixture();
    for (const route of [undefined, null, '', 'B', 'notification-sync ', 1, true, {}, [],
      f.types.WearableReminderRoute.WEAR_ENGINE, f.types.WearableReminderRoute.NOTIFICATION_SYNC]) {
      for (const enabled of [false, true]) {
        const settings = f.types.createDefaultSettings();
        settings.wearableReminder = enabled;
        settings.vibration = false; settings.reduceReminderMotion = true;
        settings.profile.sampleIntervalMs = 5000; settings.profile.calibratedAt = f.now() - 1000;
        if (route === undefined) delete settings.wearableReminderRoute;
        else settings.wearableReminderRoute = route;
        f.values.set('app_data', JSON.stringify({ settings, records: [], lastUpdatedAt: f.now() }));
        const loaded = await f.storage.loadWithStatus(f.context);
        const expected = route === f.types.WearableReminderRoute.WEAR_ENGINE ? route :
          f.types.WearableReminderRoute.NOTIFICATION_SYNC;
        assert.equal(loaded.isHealthy, true); assert.equal(loaded.data.settings.wearableReminderRoute, expected);
        assert.equal(loaded.data.settings.wearableReminder, enabled);
        assert.equal(loaded.data.settings.vibration, false); assert.equal(loaded.data.settings.reduceReminderMotion, true);
        assert.deepEqual(normalize(loaded.data.settings.profile), normalize(settings.profile));
        assert.equal(await f.storage.save(f.context, loaded.data), true);
        assert.equal(JSON.parse(f.values.get('app_data')).settings.wearableReminderRoute, expected);
      }
    }
    noNotificationMutation(f); noWear(f);
  });

  await check('B readiness and explicit test need no client, Wear capability or device selection', async () => {
    const f = fixture({ configured: false, supported: false, devices: [] });
    await f.readyNotification();
    assert.equal(f.controller.state().status, f.model.WearableStatus.READY);
    assert.equal(f.controller.state().selectedId, ''); assert.equal(f.controller.state().devices.length, 0);
    assert.equal(f.controller.state().canTest, true);
    await f.controller.test();
    assert.equal(f.calls.publishes.length, 1);
    assert.equal(f.controller.state().testRoute, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    assert.equal(f.controller.state().diagnostics[0].route, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
    assert.equal(f.controller.state().diagnostics[0].isTest, true);
    noWear(f);
  });

  await check('B prepare checks permission and slot without publishing, cooldown or business writes', async () => {
    const f = fixture(); await f.readyNotification();
    assert.ok(f.calls.enabled >= 2); assert.equal(f.calls.slots, 1);
    assert.deepEqual(f.calls.addedSlots, [2]); assert.equal(f.calls.authorizations.length, 0);
    assert.equal(f.calls.publishes.length, 0); assert.equal(f.calls.saved, 0);
    assert.equal(f.controller.state().cooldownRemainingMs, 0); assert.equal(f.controller.state().testAt, 0);
    f.controller.select('route-a'); assert.equal(f.controller.state().selectedId, '');
    f.update({ guarding: true, testAllowed: false }); await f.advance(120000);
    assert.equal(f.calls.publishes.length, 0); noWear(f);
  });

  await check('B silent refresh never requests authorization, creates slots or publishes even when permission is off', async () => {
    for (const enabled of [false, true]) {
      const f = fixture({ notificationEnabled: enabled, configured: false, supported: false });
      await f.readyNotification(false);
      assert.equal(f.controller.state().status, enabled ? f.model.WearableStatus.READY : f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.calls.enabled, 1); assert.equal(f.calls.slots, enabled ? 1 : 0);
      assert.equal(f.calls.saved, 0); assert.equal(f.controller.state().testAt, 0);
      noNotificationMutation(f); noWear(f);
    }
  });

  await check('enabled unchecked B passively checks the first confirmed real severe sample without preparing or testing', async () => {
    const f = pageFixture({ route: 'notification-sync', configured: false, supported: false });
    assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
    assert.equal(f.controller.state().canTest, false);
    await f.controller.test(); await flush();
    assert.equal(f.calls.enabled, 0); assert.equal(f.calls.slots, 0); noNotificationMutation(f);
    await f.capture(46); await f.capture(46, 3000);
    assert.equal(f.calls.enabled, 0); assert.equal(f.calls.publishes.length, 0);
    await f.capture(46, 3000);
    assert.equal(f.calls.enabled, 1); assert.equal(f.calls.slots, 1); assert.equal(f.calls.publishes.length, 1);
    assert.match(f.calls.publishes[0].request.content.normal.text, /46分.*请抬头/);
    assert.equal(f.controller.state().testAt, 0); assert.equal(f.controller.state().diagnostics[0].isTest, false);
    assert.equal(f.pageCalls.phone, 1); assert.equal(f.calls.authorizations.length, 0);
    assert.equal(f.calls.addedSlots.length, 0);
    f.p.isGuarding = false; f.p.activeTab = 3; f.p.syncWearableRuntime(); await f.advance(10001);
    assert.equal(f.controller.state().canTest, true, 'The successful passive check must establish readiness');
    assert.equal(f.calls.publishes.length, 1); noWear(f);
  });

  await check('a failed first passive B check blocks subsequent frames until an explicit successful recheck', async () => {
    for (const phase of ['permission', 'slot-missing', 'slot-disabled', 'level-none']) {
      const f = pageFixture({ route: 'notification-sync', configured: false, supported: false });
      if (phase === 'permission') f.config.notificationEnabled = false;
      if (phase === 'slot-missing') f.config.getSlot = () => Promise.resolve(undefined);
      if (phase === 'slot-disabled') f.config.slotEnabled = false;
      if (phase === 'level-none') f.config.getSlot = () => Promise.resolve({ enabled: true, notificationLevel: 0 });
      await f.capture(49); await f.capture(49, 3000); await f.capture(49, 3000);
      assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.calls.enabled, 1); assert.equal(f.calls.slots, phase === 'permission' ? 0 : 1);
      const queries = { enabled: f.calls.enabled, slots: f.calls.slots };
      f.config.notificationEnabled = true; f.config.slotEnabled = true; f.config.getSlot = undefined;
      f.p.onWearableSettingsChanged();
      for (let i = 0; i < 22; i++) await f.capture(49, 3000);
      assert.equal(f.calls.enabled, queries.enabled); assert.equal(f.calls.slots, queries.slots);
      assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.calls.saved, 0); noNotificationMutation(f);
      await f.controller.refresh(); await flush();
      assert.equal(f.controller.state().status, f.model.WearableStatus.READY);
      assert.equal(f.calls.publishes.length, 0, 'Successful recheck cannot replay discarded severe samples');
      await f.capture(48, 3000); assert.equal(f.calls.publishes.length, 1);
      assert.match(f.calls.publishes[0].request.content.normal.text, /48分/);
      assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
    }
  });

  await check('ready B survives a settings-navigation cancellation of refresh and ignores the old query result', async () => {
    for (const phase of ['permission', 'slot']) {
      for (const outcome of ['resolve', 'reject']) {
        const f = fixture({ configured: false, supported: false }); await f.readyNotification(false);
        const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else f.config.getSlot = () => gate.promise;
        const refreshing = f.controller.refresh(); await flush();
        assert.equal(f.controller.state().busy, true);
        f.update({ testAllowed: false }); await refreshing; await flush();
        assert.equal(f.controller.state().status, f.model.WearableStatus.READY);
        assert.equal(f.controller.state().busy, false); noNotificationMutation(f);
        f.update({ testAllowed: true }); assert.equal(f.controller.state().canTest, true);
        f.config.getEnabled = undefined; f.config.getSlot = undefined;
        f.severe(42); await flush(); assert.equal(f.calls.publishes.length, 1);
        const snapshot = normalize(f.controller.state()), saved = f.calls.saved;
        if (outcome === 'resolve') gate.resolve(phase === 'permission' ? true : { enabled: true, notificationLevel: 4 });
        else gate.reject(Object.assign(Error('old refresh failed'), { code: 1600004 }));
        await flush(); assert.deepEqual(normalize(f.controller.state()), snapshot);
        assert.equal(f.calls.saved, saved); assert.equal(f.calls.publishes.length, 1);
        assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
      }
    }
  });

  await check('starting real guard cancels cold or ready B refresh without stranding the next confirmed severe sample', async () => {
    for (const ready of [false, true]) {
      for (const phase of ['permission', 'slot']) {
        for (const outcome of ['resolve', 'reject']) {
          const f = pageFixture({ route: 'notification-sync', configured: false, supported: false });
          f.p.isGuarding = false; f.p.activeTab = 3; f.p.syncWearableRuntime();
          if (ready) await f.ready();
          const gate = deferred();
          if (phase === 'permission') f.config.getEnabled = () => gate.promise;
          else f.config.getSlot = () => gate.promise;
          const refreshing = f.controller.refresh(); await flush();
          assert.equal(f.controller.state().busy, true);
          f.p.isStartingGuard = true; f.p.syncWearableRuntime(); await refreshing; await flush();
          assert.equal(f.controller.state().busy, false);
          assert.equal(f.controller.state().status, ready ? f.model.WearableStatus.READY : f.model.WearableStatus.CONFIGURATION);
          f.p.isStartingGuard = false; f.p.isGuarding = true; f.p.activeTab = 0; f.p.syncWearableRuntime();
          f.config.getEnabled = undefined; f.config.getSlot = undefined;
          const queries = f.calls.enabled;
          await f.capture(49); await f.capture(49, 3000);
          assert.equal(f.calls.enabled, queries); assert.equal(f.calls.publishes.length, 0);
          await f.capture(49, 3000); assert.equal(f.calls.publishes.length, 1);
          assert.equal(f.calls.enabled, queries + 1); assert.equal(f.pageCalls.phone, 1);
          const snapshot = normalize(f.controller.state()), saved = f.calls.saved;
          if (outcome === 'resolve') gate.resolve(phase === 'permission' ? true : { enabled: true, notificationLevel: 4 });
          else gate.reject(Object.assign(Error('late startup refresh failed'), { code: 1600004 }));
          await flush(); assert.deepEqual(normalize(f.controller.state()), snapshot);
          assert.equal(f.calls.saved, saved); assert.equal(f.calls.publishes.length, 1);
          assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
        }
      }
    }
  });

  await check('real cold-start B recheck cancelled by guard startup waits for a new severe candidate without late replay', async () => {
    for (const order of ['settings-first', 'service-first']) {
      for (const phase of ['permission', 'slot']) {
        const f = startupFixture({ configured: false, supported: false }); const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else f.config.getSlot = () => gate.promise;
        const initialize = f.p.initializeWearable(1), load = f.p.loadData(1);
        if (order === 'settings-first') {
          f.settings.resolve(); await load; f.initialization.resolve(); await initialize;
        } else {
          f.initialization.resolve(); await initialize; f.settings.resolve(); await load;
        }
        await flush(); assert.equal(f.controller.state().busy, true);
        f.p.isStartingGuard = true; f.p.syncWearableRuntime(); await flush();
        f.p.isStartingGuard = false; f.p.isGuarding = true; f.p.activeTab = 0; f.p.syncWearableRuntime();
        assert.equal(f.controller.state().busy, false);
        assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
        const queries = { enabled: f.calls.enabled, slots: f.calls.slots };
        f.config.getEnabled = undefined; f.config.getSlot = undefined;
        gate.resolve(phase === 'permission' ? true : { enabled: true, notificationLevel: 4 }); await flush();
        assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
        assert.equal(f.calls.enabled, queries.enabled); assert.equal(f.calls.slots, queries.slots);
        assert.equal(f.calls.saved, 0); noNotificationMutation(f);
        f.p.lowScoreLatestScore = 45; f.p.lowScoreLevel = 3; f.p.lowScoreExpiresAt = f.now() + 7000;
        f.p.syncWearableRuntime();
        f.controller.submit(Object.assign(new f.rules.LowScoreDecision(), {
          level: 3, validSample: true, expiresAt: f.now() + 7000, alertType: f.types.PostureAlertType.ITEM_03
        }), 45, f.now()); await flush();
        assert.equal(f.calls.publishes.length, 1); assert.equal(f.calls.enabled, queries.enabled + 1);
        assert.match(f.calls.publishes[0].request.content.normal.text, /45分/);
        assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0);
        await f.service.destroy(f.pageId); noWear(f);
      }
    }
  });

  await check('a cancelled first passive B check cannot clear or deliver a newer pending severe candidate', async () => {
    for (const phase of ['permission', 'slot']) {
      for (const outcome of ['resolve', 'reject']) {
        const f = fixture({ configured: false, supported: false });
        f.controller.setRoute('notification-sync'); f.controller.setEnabled(true);
        const old = deferred(), current = deferred();
        const key = phase === 'permission' ? 'getEnabled' : 'getSlot';
        f.config[key] = () => old.promise;
        f.severe(46); await flush(); assert.equal(f.controller.state().busy, true);
        f.update({ score: 51 }); await flush();
        assert.equal(f.controller.state().busy, false); assert.equal(f.calls.saved, 0);
        await f.advance(1); f.config[key] = () => current.promise;
        f.severe(41); await flush(); assert.equal(f.controller.state().busy, true);
        const queries = { enabled: f.calls.enabled, slots: f.calls.slots };
        if (outcome === 'resolve') old.resolve(phase === 'permission' ? true : { enabled: true, notificationLevel: 4 });
        else old.reject(Object.assign(Error('old candidate check failed'), { code: 1600004 }));
        await flush(); assert.equal(f.controller.state().busy, true);
        assert.equal(f.controller.state().status, f.model.WearableStatus.CHECKING);
        assert.equal(f.calls.enabled, queries.enabled); assert.equal(f.calls.slots, queries.slots);
        assert.equal(f.calls.saved, 0); assert.equal(f.calls.publishes.length, 0);
        current.resolve(phase === 'permission' ? true : { enabled: true, notificationLevel: 4 }); await flush();
        assert.equal(f.calls.publishes.length, 1); assert.equal(f.controller.state().busy, false);
        assert.match(f.calls.publishes[0].request.content.normal.text, /41分/);
        assert.equal(f.controller.state().diagnosticCount, 1); assert.equal(f.calls.maxActive.publish, 1);
        assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
      }
    }
  });

  await check('an actual failed B refresh clears cached readiness and does not passively retry every severe frame', async () => {
    for (const phase of ['permission', 'slot', 'error']) {
      const f = fixture({ configured: false, supported: false }); await f.readyNotification(false);
      assert.equal(f.controller.state().canTest, true);
      if (phase === 'permission') f.config.notificationEnabled = false;
      if (phase === 'slot') f.config.slotEnabled = false;
      if (phase === 'error') f.config.getEnabled = () => Promise.reject(Object.assign(Error('check failed'), { code: 1600001 }));
      await f.controller.refresh();
      assert.equal(f.controller.state().status, phase === 'error' ? f.model.WearableStatus.FAILED : f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.controller.state().canTest, false);
      const queries = { enabled: f.calls.enabled, slots: f.calls.slots };
      f.config.notificationEnabled = true; f.config.slotEnabled = true; f.config.getEnabled = undefined;
      await f.controller.test();
      for (let i = 0; i < 22; i++) { await f.advance(3000); f.severe(); await flush(); }
      assert.equal(f.calls.enabled, queries.enabled); assert.equal(f.calls.slots, queries.slots);
      assert.equal(f.calls.saved, 0); assert.equal(f.controller.state().cooldownRemainingMs, 0);
      noNotificationMutation(f); noWear(f);
    }
  });

  await check('B passive checking rearms on attach, enabled changes and route changes but not identical settings updates', async () => {
    for (const reset of ['attach', 'enabled', 'route']) {
      const f = fixture({ configured: false, supported: false, notificationEnabled: false });
      f.controller.setRoute('notification-sync'); f.controller.setEnabled(true); f.severe(); await flush();
      assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION); assert.equal(f.calls.enabled, 1);
      f.config.notificationEnabled = true;
      f.controller.setRoute('notification-sync'); f.controller.setEnabled(true);
      await f.advance(1); f.severe(); await flush();
      assert.equal(f.calls.enabled, 1); assert.equal(f.calls.publishes.length, 0);
      if (reset === 'attach') {
        f.controller.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
          state => f.storage.saveWearable(f.context, state), new f.model.WearableLocalState(),
          new f.notificationModule.PhoneNotificationReminderChannel(f.context));
      }
      if (reset === 'enabled') { f.controller.setEnabled(false); f.controller.setEnabled(true); }
      if (reset === 'route') { f.controller.setRoute('wear-engine'); f.controller.setRoute('notification-sync'); }
      assert.equal(f.calls.enabled, 1); assert.equal(f.calls.publishes.length, 0);
      await f.advance(1); f.severe(); await flush();
      assert.equal(f.calls.enabled, 2); assert.equal(f.calls.slots, 1); assert.equal(f.calls.publishes.length, 1);
      assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0);
      noWear(f, reset === 'route');
    }
  });

  await check('real page initializes enabled B silently regardless of settings and service load order', async () => {
    for (const order of ['settings-first', 'service-first', 'together']) {
      const f = startupFixture({ configured: false, supported: false });
      const initialize = f.p.initializeWearable(1), load = f.p.loadData(1); await flush();
      assert.equal(f.bootCalls.initializes, 1); assert.equal(f.bootCalls.reads, 1);
      if (order === 'settings-first') {
        f.settings.resolve(); await load; await flush();
        assert.equal(f.p.loaded, true); assert.equal(f.calls.enabled, 0);
        assert.notEqual(f.controller.state().status, f.model.WearableStatus.READY);
        f.initialization.resolve(); await initialize;
      } else if (order === 'service-first') {
        f.initialization.resolve(); await initialize; await flush();
        assert.equal(f.p.loaded, false); assert.equal(f.calls.enabled, 0);
        f.settings.resolve(); await load;
      } else {
        f.settings.resolve(); f.initialization.resolve(); await Promise.all([initialize, load]);
      }
      await flush();
      assert.equal(f.p.loaded, true); assert.equal(f.p.settings.wearableReminder, true);
      assert.equal(f.p.settings.wearableReminderRoute, 'notification-sync');
      assert.equal(f.controller.state().route, 'notification-sync');
      assert.equal(f.controller.state().status, f.model.WearableStatus.READY, order);
      assert.equal(f.controller.state().canTest, true); assert.equal(f.controller.state().busy, false);
      assert.ok(f.calls.enabled > 0); assert.ok(f.calls.slots > 0);
      assert.equal(f.calls.maxActive.enabled, 1); assert.equal(f.calls.maxActive.slot, 1);
      assert.equal(f.calls.saved, 0); assert.equal(f.p.records.length, 0);
      assert.equal(f.controller.state().cooldownRemainingMs, 0); noNotificationMutation(f);
      await f.service.destroy(f.pageId); noWear(f);
    }
  });

  await check('real page startup refuses unprepared B without opening permission or mutating the slot', async () => {
    for (const order of ['settings-first', 'service-first']) {
      for (const readiness of ['permission-off', 'slot-missing', 'slot-disabled', 'level-none']) {
        const f = startupFixture({ configured: false, supported: false });
        if (readiness === 'permission-off') f.config.notificationEnabled = false;
        if (readiness === 'slot-missing') f.config.getSlot = () => Promise.resolve(undefined);
        if (readiness === 'slot-disabled') f.config.slotEnabled = false;
        if (readiness === 'level-none') f.config.getSlot = () => Promise.resolve({ enabled: true, notificationLevel: 0 });
        const initialize = f.p.initializeWearable(1), load = f.p.loadData(1);
        if (order === 'settings-first') {
          f.settings.resolve(); await load; f.initialization.resolve(); await initialize;
        } else {
          f.initialization.resolve(); await initialize; f.settings.resolve(); await load;
        }
        await flush(); assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
        assert.equal(f.controller.state().canTest, false); assert.equal(f.controller.state().busy, false);
        assert.ok(f.calls.enabled > 0); assert.equal(f.calls.saved, 0); noNotificationMutation(f);
        await f.service.destroy(f.pageId); noWear(f);
      }
    }
  });

  await check('real page startup keeps explicit A and disabled B free of notification queries', async () => {
    for (const route of ['wear-engine', 'notification-sync']) {
      for (const enabled of [false, true]) {
        if (route === 'notification-sync' && enabled) continue;
        const f = startupFixture({ route, wearable: enabled });
        const initialize = f.p.initializeWearable(1), load = f.p.loadData(1);
        f.initialization.resolve(); f.settings.resolve(); await Promise.all([initialize, load]); await flush();
        assert.equal(f.controller.state().route, route); assert.equal(f.p.settings.wearableReminder, enabled);
        assert.equal(f.calls.enabled, 0); assert.equal(f.calls.slots, 0); noNotificationMutation(f);
        await f.service.destroy(f.pageId);
        assert.equal(f.calls.devices, 0); assert.equal(f.calls.notifyClients, 0); assert.equal(f.calls.on, 0);
      }
    }
  });

  await check('B refresh and formal guard never request permission or create a slot', async () => {
    for (const phase of ['permission', 'slot']) {
      const f = fixture(); await f.readyNotification(false);
      if (phase === 'permission') f.config.notificationEnabled = false;
      else f.config.slotEnabled = false;
      f.severe(); await flush();
      assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
      await f.controller.prepareNotificationSync(); await f.controller.refresh(); await f.advance(60001);
      assert.equal(f.controller.state().busy, false); noNotificationMutation(f); noWear(f);
    }
    const unsupported = fixture({ notificationSupported: false });
    await unsupported.readyNotification();
    assert.equal(unsupported.controller.state().status, unsupported.model.WearableStatus.UNSUPPORTED);
    assert.equal(unsupported.calls.enabled, 0); noNotificationMutation(unsupported); noWear(unsupported);
  });

  await check('B explicit authorization resolve is rechecked before slot creation and readiness', async () => {
    for (const grants of [false, true]) {
      const f = fixture({ notificationEnabled: false });
      const gate = deferred(); f.config.authorize = () => gate.promise;
      const preparing = f.readyNotification(); await flush();
      assert.equal(f.calls.authorizations.length, 1); assert.equal(f.calls.enabled, 1);
      assert.equal(f.calls.addedSlots.length, 0); assert.equal(f.controller.state().busy, true);
      f.config.notificationEnabled = grants; gate.resolve(); await preparing;
      assert.ok(f.calls.enabled >= 2, 'Resolved permission dialog is not proof of authorization');
      assert.equal(f.controller.state().status, grants ? f.model.WearableStatus.READY : f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.calls.addedSlots.length, grants ? 1 : 0);
      assert.equal(f.calls.publishes.length, 0); assert.equal(f.calls.saved, 0); noWear(f);
    }
  });

  await check('B authorization rejection, synchronous errors and disabled slots never become ready', async () => {
    for (const sync of [false, true]) {
      const f = fixture({ notificationEnabled: false });
      f.config.authorize = () => {
        const error = Object.assign(Error('permission denied'), { code: 1600004 });
        if (sync) throw error;
        return Promise.reject(error);
      };
      await f.readyNotification();
      assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.controller.state().busy, false); assert.equal(f.controller.state().canTest, false);
      assert.equal(f.calls.addedSlots.length, 0); assert.equal(f.calls.publishes.length, 0); noWear(f);
    }
    const disabled = fixture({ slotEnabled: false }); await disabled.readyNotification();
    assert.equal(disabled.controller.state().status, disabled.model.WearableStatus.CONFIGURATION);
    assert.equal(disabled.controller.state().canTest, false); assert.equal(disabled.calls.publishes.length, 0);
    assert.equal(disabled.config.slotEnabled, false, 'Preparation must not override a disabled user slot');
    noWear(disabled);
  });

  await check('B missing slot and LEVEL_NONE fail closed and never recreate a slot during guard', async () => {
    for (const slot of [undefined, null, { enabled: false, notificationLevel: 4 },
      { enabled: false, notificationLevel: 0 }, { enabled: true, notificationLevel: 0 }]) {
      const f = fixture(); await f.readyNotification(false);
      f.config.getSlot = () => Promise.resolve(slot); f.severe(); await flush();
      assert.equal(f.controller.state().status, f.model.WearableStatus.CONFIGURATION);
      assert.equal(f.controller.state().canTest, false); assert.equal(f.calls.saved, 0);
      await f.controller.refresh(); await f.advance(60001);
      noNotificationMutation(f); noWear(f);
    }
  });

  await check('B channel accepts active slot fields and rejects absent or disabled slots in both check and prepare', async () => {
    for (const slot of [undefined, null, { enabled: false, notificationLevel: 4 }, { notificationLevel: 0 },
      { enabled: true, notificationLevel: 0 }, { enabled: true, notificationLevel: 4 }, { notificationLevel: 4 }]) {
      for (const prepare of [false, true]) {
        const f = fixture({ getSlot: () => Promise.resolve(slot) });
        const action = prepare ? f.notificationChannel.prepare(() => true) : f.notificationChannel.check(() => true);
        const disabled = !slot || slot.enabled === false || slot.notificationLevel === 0;
        if (disabled) await assert.rejects(action, error => error instanceof f.channelModule.WearableChannelError &&
          error.status === f.model.WearableStatus.CONFIGURATION);
        else await action;
        assert.equal(f.calls.slots, 1); assert.equal(f.calls.authorizations.length, 0);
        assert.equal(f.calls.addedSlots.length, prepare ? 1 : 0);
        assert.equal(f.calls.publishes.length, 0); assert.equal(f.calls.saved, 0); noWear(f);
      }
    }
  });

  await check('B preparation cancels at permission, authorization and slot awaits without late writes', async () => {
    const cancellations = [f => f.controller.setEnabled(false), f => f.controller.setRoute(f.types.WearableReminderRoute.WEAR_ENGINE),
      f => f.update({ foreground: false }), f => f.update({ calibrating: true }), f => f.update({ guarding: true }),
      f => f.update({ testAllowed: false }), f => f.update({ pageId: 2 }), f => f.update({ sessionId: 2 }),
      f => f.controller.close()];
    for (const phase of ['permission', 'authorization', 'slot']) {
      for (const cancel of cancellations) {
        const f = fixture({ notificationEnabled: phase !== 'authorization' });
        const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        if (phase === 'authorization') f.config.authorize = () => gate.promise;
        if (phase === 'slot') f.config.addSlot = () => gate.promise;
        const preparing = f.readyNotification(); await flush();
        const enabled = f.calls.enabled, slots = f.calls.slots, added = f.calls.addedSlots.length;
        noWear(f); await cancel(f); f.config.notificationEnabled = true;
        gate.resolve(phase === 'permission' ? false : undefined); await preparing; await flush();
        assert.equal(f.calls.enabled, enabled, phase + ': no late permission recheck');
        assert.equal(f.calls.slots, slots, phase + ': no late slot query');
        assert.equal(f.calls.addedSlots.length, added, phase + ': no late slot creation');
        assert.equal(f.calls.publishes.length, 0); assert.notEqual(f.controller.state().status, f.model.WearableStatus.CHECKING);
        assert.equal(f.controller.state().busy, false); noWear(f, f.controller.state().route === 'wear-engine');
      }
    }
  });

  await check('B permission timeout ignores late acceptance and serializes outstanding authorization', async () => {
    const f = fixture({ notificationEnabled: false });
    const gate = deferred(); f.config.authorize = () => gate.promise;
    const first = f.readyNotification(); await flush();
    await f.advance(59999); assert.equal(f.controller.state().status, f.model.WearableStatus.CHECKING);
    await f.advance(1); await first;
    assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
    assert.equal(f.controller.state().busy, false); assert.equal(f.calls.authorizations.length, 1);
    const second = f.controller.prepareNotificationSync(); await flush();
    assert.equal(f.calls.authorizations.length, 1, 'Outstanding system dialog must be reused');
    f.update({ foreground: false }); gate.resolve(); await second; await flush();
    assert.equal(f.calls.addedSlots.length, 0); assert.equal(f.calls.publishes.length, 0);
    assert.equal(f.calls.maxActive.authorization, 1); noWear(f);
  });

  await check('late B permission acceptance after timeout cannot create a slot, publish or mark ready', async () => {
    for (const outcome of ['resolve', 'reject']) {
      const f = fixture({ notificationEnabled: false }); const gate = deferred();
      f.config.authorize = () => gate.promise; const preparing = f.readyNotification(); await flush();
      await f.advance(60000); await preparing;
      assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
      const queries = f.calls.enabled; f.config.notificationEnabled = true;
      if (outcome === 'resolve') gate.resolve();
      else gate.reject(Object.assign(Error('late denial'), { code: 1600004 }));
      await flush(); assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
      assert.equal(f.calls.enabled, queries); assert.equal(f.calls.addedSlots.length, 0);
      assert.equal(f.calls.publishes.length, 0); assert.equal(f.controller.state().canTest, false);
      await f.advance(60001); assert.equal(f.calls.publishes.length, 0); noWear(f);
    }
  });

  await check('B preparation rejects late permission replies by monotonic time without running the timeout callback', async () => {
    for (const elapsed of [60000, 60001]) {
      for (const enabled of [false, true]) {
        const f = fixture(); const gate = deferred(); f.config.getEnabled = () => gate.promise;
        const preparing = f.readyNotification(); await flush();
        assert.equal(f.calls.enabled, 1); assert.equal(f.controller.state().busy, true);
        f.setClock(f.now(), f.uptime() + elapsed);
        assert.ok([...f.timers.values()].some(timer => timer.due <= f.uptime()), 'Timeout callback remains pending');
        gate.resolve(enabled); await preparing;
        assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
        assert.equal(f.controller.state().busy, false); assert.equal(f.controller.state().canTest, false);
        assert.equal(f.calls.enabled, 1); assert.equal(f.calls.slots, 0);
        assert.equal(f.calls.saved, 0); noNotificationMutation(f); noWear(f);
      }
    }
  });

  await check('B silent refresh honors the exact five-second monotonic boundary while timeout callbacks are pending', async () => {
    for (const elapsed of [4999, 5000, 5001]) {
      for (const phase of ['permission', 'slot']) {
        const f = fixture(); const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else f.config.getSlot = () => gate.promise;
        const refreshing = f.readyNotification(false); await flush();
        assert.equal(f.calls.enabled, 1); f.setClock(f.now(), f.uptime() + elapsed);
        if (elapsed >= 5000) assert.ok([...f.timers.values()].some(timer => timer.due <= f.uptime()));
        gate.resolve(phase === 'permission' ? true : { enabled: true, notificationLevel: 4 }); await refreshing;
        assert.equal(f.controller.state().status, elapsed < 5000 ? f.model.WearableStatus.READY : f.model.WearableStatus.UNKNOWN);
        assert.equal(f.controller.state().canTest, elapsed < 5000);
        assert.equal(f.controller.state().busy, false);
        assert.equal(f.calls.slots, elapsed < 5000 || phase === 'slot' ? 1 : 0);
        assert.equal(f.calls.saved, 0); noNotificationMutation(f); noWear(f);
      }
    }
  });

  await check('B preparation rechecks monotonic expiry after authorization, permission recheck and each slot await', async () => {
    for (const elapsed of [59999, 60000]) {
      for (const phase of ['authorization', 'recheck', 'addSlot', 'slot']) {
        const f = fixture(); const gate = deferred(); let queries = 0;
        if (phase === 'authorization') {
          f.config.notificationEnabled = false; f.config.authorize = () => gate.promise;
        }
        if (phase === 'recheck') f.config.getEnabled = () => ++queries === 2 ? gate.promise : Promise.resolve(true);
        if (phase === 'addSlot') f.config.addSlot = () => gate.promise;
        if (phase === 'slot') f.config.getSlot = () => gate.promise;
        const preparing = f.readyNotification(); await flush();
        const snapshot = { enabled: f.calls.enabled, slots: f.calls.slots, added: f.calls.addedSlots.length };
        assert.equal(f.calls.active[phase === 'recheck' ? 'enabled' : phase], 1, phase + ' is awaiting native result');
        f.setClock(f.now(), f.uptime() + elapsed); f.config.notificationEnabled = true;
        gate.resolve(phase === 'slot' ? { enabled: true, notificationLevel: 4 } : true); await preparing;
        assert.equal(f.controller.state().status, elapsed < 60000 ? f.model.WearableStatus.READY : f.model.WearableStatus.UNKNOWN);
        assert.equal(f.controller.state().busy, false);
        if (elapsed === 60000) {
          assert.equal(f.calls.enabled, snapshot.enabled); assert.equal(f.calls.slots, snapshot.slots);
          assert.equal(f.calls.addedSlots.length, snapshot.added);
        }
        assert.equal(f.calls.publishes.length, 0); assert.equal(f.calls.saved, 0); noWear(f);
      }
    }
  });

  await check('B authorization Promise is reused across page reconstruction without reviving old preparation', async () => {
    const f = fixture({ notificationEnabled: false }); const gate = deferred();
    f.config.authorize = () => gate.promise; const old = f.readyNotification(); await flush();
    await f.controller.close(); await old;
    f.controller.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
      state => f.storage.saveWearable(f.context, state), new f.model.WearableLocalState(),
      new f.notificationModule.PhoneNotificationReminderChannel(f.context));
    f.update({ foreground: true, pageId: 2, sessionId: 2, guarding: false, testAllowed: true });
    const current = f.readyNotification(); await flush();
    assert.equal(f.calls.authorizations.length, 1); assert.equal(f.calls.maxActive.authorization, 1);
    f.config.notificationEnabled = true; gate.resolve(); await current;
    assert.equal(f.controller.state().status, f.model.WearableStatus.READY);
    assert.equal(f.calls.addedSlots.length, 1, 'Only the current page may continue after authorization');
    assert.equal(f.calls.slots, 1); assert.equal(f.calls.publishes.length, 0); noWear(f);
  });

  await check('B real capture confirms under-50 scores after six seconds at 2/3/5 second intervals', async () => {
    for (const interval of [2000, 3000, 5000]) {
      const f = pageFixture({ route: 'notification-sync', configured: false, supported: false,
        interval, vibration: false, motor: false }); await f.ready();
      assert.equal(f.controller.state().route, f.types.WearableReminderRoute.NOTIFICATION_SYNC);
      const started = f.now(); await f.capture(47);
      while (f.now() - started < 6000) {
        assert.equal(f.calls.publishes.length, 0); await f.capture(47, interval);
      }
      assert.equal(f.calls.publishes.length, 1, interval + 'ms B confirmation');
      assert.equal(f.p.lowScoreLevel, f.rules.LowScoreLevel.SEVERE); assert.equal(f.pageCalls.phone, 0);
      assert.match(f.calls.publishes[0].request.content.normal.text, /47分.*请抬头/);
      assert.equal(f.controller.state().diagnostics[0].isTest, false); noWear(f);
    }
  });

  await check('B single samples, sub-six-second runs, 50-52 hysteresis and refresh timers never replay', async () => {
    const single = pageFixture({ route: 'notification-sync' }); await single.ready();
    await single.capture(49); await single.capture(49, 2000); await single.capture(49, 2000);
    await single.advance(60000); single.p.applyLowScoreDecision(single.p.lowScoreScheduler.refresh(
      single.p.lowScoreContext(), single.now()));
    assert.equal(single.calls.publishes.length, 0);
    for (const score of [50, 51, 52]) {
      const f = pageFixture({ route: 'notification-sync', vibration: false }); await f.ready();
      await f.capture(49); await f.capture(49, 3000); await f.capture(49, 3000);
      assert.equal(f.calls.publishes.length, 1);
      for (let i = 0; i < 21; i++) await f.capture(score, 3000);
      assert.equal(f.p.lowScoreLevel, f.rules.LowScoreLevel.SEVERE);
      assert.equal(f.calls.publishes.length, 1, score + ' is hysteresis, not a new under-50 event');
      await f.capture(49, 3000); assert.equal(f.calls.publishes.length, 2);
      const queries = f.calls.enabled; await f.advance(60001);
      assert.equal(f.calls.publishes.length, 2); assert.equal(f.calls.enabled, queries); noWear(f);
    }
    const oscillating = pageFixture({ route: 'notification-sync' }); await oscillating.ready();
    for (let i = 0; i < 30; i++) await oscillating.capture(i % 2 ? 51 : 49, i ? 3000 : 0);
    assert.equal(oscillating.calls.publishes.length, 0);
  });

  await check('B invalid, mock, manual, calibration, background and stale real captures never publish', async () => {
    for (const patch of [frame => { delete frame.skeleton.nose; }, frame => { delete frame.skeleton.leftShoulder; },
      frame => { frame.reminderEvidence.faceCount = 2; }, frame => { frame.reminderEvidence.skeletonCount = 0; },
      frame => { frame.face.confidence = 0; }, frame => { frame.reminderEvidence.associationAmbiguous = true; },
      frame => { frame.result.timestamp--; }, frame => { frame.result.score = NaN; }]) {
      const f = pageFixture({ route: 'notification-sync' }); await f.ready();
      await f.capture(49, 0, patch); await f.capture(49, 3000, patch); await f.capture(49, 3000, patch);
      assert.equal(f.calls.publishes.length, 0, patch.toString()); noNotificationMutation(f); noWear(f);
    }
    for (const patch of [{ isGuarding: false, isManualOperation: true }, { isCalibrating: true },
      { appForeground: false }]) {
      const f = pageFixture({ route: 'notification-sync' }); await f.ready(); Object.assign(f.p, patch);
      await f.capture(49, 0, () => {}, true); await f.capture(49, 3000, () => {}, true);
      await f.capture(49, 3000, () => {}, true); assert.equal(f.calls.publishes.length, 0); noWear(f);
    }
    const mock = pageFixture({ route: 'notification-sync' }); await mock.ready(); mock.p.settings.useCoreVision = false;
    await mock.capture(49); await mock.capture(49, 3000); await mock.capture(49, 3000);
    assert.equal(mock.calls.publishes.length, 0);
    const stale = pageFixture({ route: 'notification-sync' }); await stale.ready();
    await stale.capture(49); await stale.capture(49, 3000);
    await stale.advance(3000); stale.setFrame(49); const gate = deferred();
    stale.p.postureSource.sample = () => gate.promise;
    const capture = stale.p.captureFrame(); stale.p.guardRunId++; gate.resolve(stale.p.frame); await capture; await flush();
    assert.equal(stale.calls.publishes.length, 0); noWear(stale);
  });

  await check('B quiet fixed-ID payload contains only minimal notification data and no test score', async () => {
    const f = fixture(); await f.readyNotification(false); await f.controller.test();
    const test = f.calls.publishes[0];
    assert.equal(test.request.id, 29002); assert.equal(test.request.label, 'zuozhile-posture-reminder');
    assert.equal(test.request.notificationSlotType, 2);
    assert.deepEqual(normalize(test.request.notificationFlags), { soundEnabled: 2, vibrationEnabled: 2 });
    assert.equal(test.request.autoDeletedTime, test.at + 60000);
    assert.equal(test.request.content.notificationContentType, 0);
    assert.match(test.request.content.normal.title, /测试/); assert.match(test.request.content.normal.text, /测试.*不计入/);
    assert.doesNotMatch(JSON.stringify(test.request.content), /\d+分|当前|score|baseline|frame|randomId/);
    assert.deepEqual(Object.keys(test.request).sort(),
      ['autoDeletedTime', 'content', 'id', 'label', 'notificationFlags', 'notificationSlotType']);
    assert.deepEqual(Object.keys(test.request.content).sort(), ['normal', 'notificationContentType']);
    assert.deepEqual(Object.keys(test.request.content.normal).sort(), ['additionalText', 'text', 'title']);
    await f.advance(10000); f.severe(43); await flush();
    assert.equal(f.calls.publishes.length, 2);
    const formal = f.calls.publishes[1];
    assert.equal(formal.request.id, test.request.id); assert.equal(formal.request.label, test.request.label);
    assert.equal(formal.request.autoDeletedTime, formal.at + 60000);
    assert.deepEqual(normalize(formal.request.notificationFlags), { soundEnabled: 2, vibrationEnabled: 2 });
    assert.match(formal.request.content.normal.text, /43分.*请抬头/);
    assert.doesNotMatch(JSON.stringify(formal.request), /extra|alertOnce|wantAgent|actionButtons|onAction|route-a/);
    assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
  });

  await check('B business records and original phone short vibration match disabled wearable behavior', async () => {
    const enabled = pageFixture({ route: 'notification-sync' });
    const disabled = pageFixture({ route: 'notification-sync', wearable: false }); await enabled.ready();
    for (let i = 0; i < 24; i++) {
      await enabled.capture(49, i ? 3000 : 0); await disabled.capture(49, i ? 3000 : 0);
    }
    assert.equal(enabled.calls.publishes.length, 6); assert.equal(disabled.calls.publishes.length, 0);
    assert.equal(enabled.pageCalls.phone, 2); assert.equal(enabled.pageCalls.phone, disabled.pageCalls.phone);
    assert.deepEqual(normalize(enabled.p.records), normalize(disabled.p.records));
    assert.equal(enabled.pageCalls.saved, disabled.pageCalls.saved);
    const snapshot = normalize(enabled.p.records), saved = enabled.pageCalls.saved;
    enabled.controller.confirm(enabled.model.WearableTestConfirmation.VIBRATED); await flush();
    assert.deepEqual(normalize(enabled.p.records), snapshot); assert.equal(enabled.pageCalls.saved, saved);
    noNotificationMutation(disabled); noWear(enabled); noWear(disabled);
  });

  await check('B and phone retain independent cooldowns and phone feedback survives B publish failure', async () => {
    const f = pageFixture({ route: 'notification-sync' }); await f.ready(); f.phoneCooldown.claim(f.now());
    await f.capture(49); await f.capture(49, 3000); await f.capture(49, 3000);
    assert.equal(f.calls.publishes.length, 1); assert.equal(f.pageCalls.phone, 0);
    for (let i = 0; i < 18; i++) await f.capture(49, 3000);
    assert.equal(f.pageCalls.phone, 1); assert.equal(f.calls.publishes.length, 5);
    await f.capture(49, 6000); assert.equal(f.calls.publishes.length, 6);
    const failed = pageFixture({ route: 'notification-sync', publish: () => Promise.reject(
      Object.assign(Error('publish failed'), { code: 1600001 })) }); await failed.ready();
    await failed.capture(49); await failed.capture(49, 3000); await failed.capture(49, 3000);
    assert.equal(failed.calls.publishes.length, 1); assert.equal(failed.pageCalls.phone, 1);
    assert.equal(failed.controller.state().status, failed.model.WearableStatus.FAILED);
    noWear(f); noWear(failed);
  });

  await check('A to B and B to A share exact 10-second cooldown and never broadcast or auto-fallback', async () => {
    for (const first of ['wear-engine', 'notification-sync']) {
      for (const testing of [false, true]) {
        for (const nextTesting of [false, true]) {
          const f = fixture();
          if (first === 'wear-engine') await f.ready(); else await f.readyNotification(false);
          if (testing) await f.controller.test(); else { f.severe(); await flush(); }
          assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
          const opposite = first === 'wear-engine' ? 'notification-sync' : 'wear-engine';
          f.controller.setRoute(opposite);
          assert.equal(f.controller.state().selectedId, ''); assert.equal(f.controller.state().devices.length, 0);
          await f.controller.refresh(); if (opposite === 'wear-engine') f.controller.select('route-b');
          if (nextTesting) f.update({ guarding: false, testAllowed: true });
          const next = async () => {
            if (nextTesting) await f.controller.test(); else f.severe();
            await flush();
          };
          await next(); assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
          await f.advance(9999); await next();
          assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
          assert.equal(f.controller.state().cooldownRemainingMs, 1);
          await f.advance(1); assert.equal(f.calls.sends.length + f.calls.publishes.length, 1, 'Timer must not replay');
          assert.equal(f.controller.state().cooldownRemainingMs, 0);
          await next();
          assert.equal(f.calls.sends.length, 1); assert.equal(f.calls.publishes.length, 1);
          assert.equal(f.controller.state().diagnostics[0].route, opposite);
          const a = f.calls.sends[0], b = f.calls.publishes[0];
          assert.equal(Math.abs(a.uptime - b.uptime), 10000);
          if (opposite === 'wear-engine') assert.equal(a.routeId, 'route-b');
          assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0);
        }
      }
    }
  });

  await check('10-second cooldown expiry timers never publish or replay a discarded formal event', async () => {
    for (const route of ['wear-engine', 'notification-sync']) {
      const f = fixture(); if (route === 'wear-engine') await f.ready(); else await f.readyNotification(false);
      f.severe(); await flush(); await f.advance(9999); f.severe(); await flush();
      assert.equal(f.controller.state().cooldownRemainingMs, 1);
      const queries = { devices: f.calls.devices, enabled: f.calls.enabled, slots: f.calls.slots };
      await f.advance(2);
      assert.equal(f.controller.state().cooldownRemainingMs, 0);
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      assert.deepEqual({ devices: f.calls.devices, enabled: f.calls.enabled, slots: f.calls.slots }, queries);
      f.severe(); await flush(); assert.equal(f.calls.sends.length + f.calls.publishes.length, 2);
    }
  });

  await check('10-second shared cooldown starts at SDK submission after slow durable storage', async () => {
    for (const route of ['wear-engine', 'notification-sync']) {
      const f = fixture(); if (route === 'wear-engine') await f.ready(); else await f.readyNotification(false);
      const gate = deferred(); let saves = 0;
      f.config.flush = () => ++saves === 1 ? gate.promise : Promise.resolve();
      f.severe(); await flush(); assert.equal(f.calls.sends.length + f.calls.publishes.length, 0);
      await f.advance(4000); gate.resolve(); await flush();
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      const first = f.calls.sends[0] || f.calls.publishes[0];
      assert.equal(f.controller.state().cooldownRemainingMs, 10000);
      await f.advance(9999); f.severe(); await flush();
      assert.equal(f.controller.state().cooldownRemainingMs, 1);
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      await f.advance(1); f.severe(); await flush();
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 2);
      const second = f.calls.sends[1] || f.calls.publishes[1];
      assert.equal(second.uptime - first.uptime, 10000);
    }
  });

  await check('both routes restore shared persisted cooldown after controller reconstruction', async () => {
    for (const first of ['wear-engine', 'notification-sync']) {
      const f = fixture();
      if (first === 'wear-engine') await f.ready(); else await f.readyNotification(false);
      await f.controller.test(); const at = f.now(), started = f.uptime();
      const local = await f.storage.loadWearable(f.context);
      assert.ok(local.lastAttemptAt >= at && local.lastAttemptAt <= at + 5000);
      assert.ok(local.lastAttemptUptime >= started && local.lastAttemptUptime <= started + 5000);
      assert.equal(local.testRoute, first); await f.controller.close(); await f.advance(5000);
      const policy = new f.model.WearableReminderPolicy();
      const rebuilt = new f.serviceModule.WearableReminderController(f.clock, policy);
      rebuilt.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
        state => f.storage.saveWearable(f.context, state), local,
        new f.notificationModule.PhoneNotificationReminderChannel(f.context));
      const route = first === 'wear-engine' ? 'notification-sync' : 'wear-engine';
      rebuilt.setRoute(route); rebuilt.update(Object.assign(new f.model.WearableRuntime(), {
        foreground: true, pageId: 2, sessionId: 2, testAllowed: true
      })); rebuilt.setEnabled(true); await rebuilt.refresh();
      if (route === 'wear-engine') rebuilt.select('route-a');
      assert.ok(rebuilt.state().cooldownRemainingMs >= 5000 && rebuilt.state().cooldownRemainingMs <= 10000);
      await rebuilt.test(); assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      await f.advance(rebuilt.state().cooldownRemainingMs - 1); await rebuilt.test();
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      await f.advance(1); assert.equal(rebuilt.state().cooldownRemainingMs, 0);
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      await rebuilt.test(); assert.equal(f.calls.sends.length, 1); assert.equal(f.calls.publishes.length, 1);
    }
  });

  await check('switching either route cancels pending query and requires a new event without replay', async () => {
    for (const first of ['wear-engine', 'notification-sync']) {
      const f = fixture(); if (first === 'wear-engine') await f.ready(); else await f.readyNotification(false);
      const gate = deferred();
      if (first === 'wear-engine') f.config.discovery = () => gate.promise;
      else f.config.getSlot = () => gate.promise;
      f.severe(); await flush();
      const route = first === 'wear-engine' ? 'notification-sync' : 'wear-engine';
      f.controller.setRoute(route); await f.controller.refresh();
      if (route === 'wear-engine') f.controller.select('route-b');
      gate.resolve(first === 'wear-engine' ? f.config.devices : { enabled: true }); await flush();
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 0);
      assert.notEqual(f.controller.state().status, f.model.WearableStatus.CHECKING);
      await f.advance(60001); assert.equal(f.calls.sends.length + f.calls.publishes.length, 0);
      f.config.discovery = undefined; f.config.getSlot = undefined; f.severe(); await flush();
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      assert.equal(route === 'wear-engine' ? f.calls.publishes.length : f.calls.sends.length, 0);
    }
  });

  await check('B query continuations respect every formal cancellation boundary', async () => {
    const cancellations = [f => f.controller.setEnabled(false), f => f.update({ foreground: false }),
      f => f.update({ calibrating: true }), f => f.update({ pageId: 2 }), f => f.update({ sessionId: 2 }),
      f => f.update({ guarding: false }), f => f.update({ realSource: false }), f => f.update({ score: 50 }),
      f => f.update({ expiresAt: 0 }), f => f.controller.close()];
    for (const phase of ['permission', 'slot']) {
      for (const cancel of cancellations) {
        const f = fixture(); await f.readyNotification(false); const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else f.config.getSlot = () => gate.promise;
        f.severe(); await flush(); const slots = f.calls.slots;
        await cancel(f); gate.resolve(phase === 'permission' ? true : { enabled: true }); await flush();
        assert.equal(f.calls.publishes.length, 0, phase + ': ' + cancel.toString());
        assert.equal(f.calls.slots, slots, 'Cancelled permission query must not continue into getSlot');
        assert.notEqual(f.controller.state().status, f.model.WearableStatus.CHECKING);
        assert.equal(f.controller.state().busy, false); await f.advance(60001);
        assert.equal(f.calls.publishes.length, 0); noNotificationMutation(f); noWear(f);
      }
    }
  });

  await check('B tests cancel during permission and slot queries when leaving idle settings', async () => {
    for (const phase of ['permission', 'slot']) {
      for (const patch of [{ testAllowed: false }, { calibrating: true }, { guarding: true },
        { foreground: false }, { pageId: 2 }, { sessionId: 2 }]) {
        const f = fixture(); await f.readyNotification(false); const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else f.config.getSlot = () => gate.promise;
        const testing = f.controller.test(); await flush();
        f.update(patch); gate.resolve(phase === 'permission' ? true : { enabled: true });
        await testing; await flush();
        assert.equal(f.calls.publishes.length, 0); assert.equal(f.controller.state().testAt, 0);
        assert.equal(f.calls.saved, 0); assert.equal(f.controller.state().busy, false);
        noNotificationMutation(f); noWear(f);
      }
    }
  });

  await check('old A service-death callbacks do not cancel B readiness or a current B severe event', async () => {
    const f = fixture(); await f.ready();
    const deviceQueries = f.calls.devices, listens = f.calls.on;
    await f.readyNotification(false); const state = normalize(f.controller.state());
    f.die(); assert.deepEqual(normalize(f.controller.state()), state);
    const gate = deferred(); f.config.getSlot = () => gate.promise;
    f.severe(); await flush(); f.die(); gate.resolve({ enabled: true }); await flush();
    assert.equal(f.calls.publishes.length, 1); assert.equal(f.calls.sends.length, 0);
    assert.equal(f.calls.devices, deviceQueries); assert.equal(f.calls.on, listens);
  });

  await check('B real page cancels pending permission checks on invalid capture, background and disposal', async () => {
    for (const cancel of [async f => f.capture(49, 1, frame => { delete frame.skeleton.nose; }),
      async f => { f.p.appForeground = false; f.p.onForegroundChanged(); }, async f => f.p.aboutToDisappear()]) {
      const f = pageFixture({ route: 'notification-sync' }); await f.ready(); const gate = deferred();
      await f.capture(49); await f.capture(49, 3000); f.config.getEnabled = () => gate.promise;
      await f.capture(49, 3000); await cancel(f); gate.resolve(true); await flush();
      assert.equal(f.calls.publishes.length, 0); assert.equal(f.p.lowScoreDataValid, false); noWear(f);
    }
  });

  await check('B queries time out at candidate TTL and ignore late resolve or reject without fallback', async () => {
    for (const phase of ['permission', 'slot']) {
      for (const outcome of ['resolve', 'reject']) {
        const f = fixture(); await f.readyNotification(false); const gate = deferred();
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else f.config.getSlot = () => gate.promise;
        f.severe(); await flush(); const slots = f.calls.slots;
        f.severe(); await f.controller.test(); await f.controller.refresh();
        assert.equal(f.calls.maxActive[phase === 'permission' ? 'enabled' : 'slot'], 1);
        await f.advance(5000);
        assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
        assert.equal(f.controller.state().busy, false); assert.equal(f.calls.saved, 0);
        if (outcome === 'resolve') gate.resolve(phase === 'permission' ? true : { enabled: true });
        else gate.reject(Object.assign(Error('late query failure'), { code: 1600004 }));
        await flush(); assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
        assert.equal(f.calls.slots, slots); await f.advance(60001);
        assert.equal(f.calls.publishes.length, 0); noNotificationMutation(f); noWear(f);
      }
    }
  });

  await check('B event freshness is bounded by monotonic time despite wall-clock shifts', async () => {
    for (const shift of [-1000, 3600000]) {
      const f = fixture(); await f.readyNotification(false); const gate = deferred();
      f.config.getEnabled = () => gate.promise; f.severe(); await flush();
      await f.advance(5000, shift); gate.resolve(true); await flush();
      assert.equal(f.calls.slots, 1); assert.equal(f.calls.publishes.length, 0);
      assert.equal(f.calls.saved, 0); noWear(f);
    }
  });

  await check('B cooldown saves before publish and failed save blocks both routes without automatic retry', async () => {
    const f = fixture(); await f.readyNotification(false); f.severe(); await flush();
    assert.ok(f.order.indexOf('flush') >= 0); assert.ok(f.order.indexOf('flush') < f.order.indexOf('publish'));
    const failed = fixture({ save: false }); await failed.readyNotification(false); failed.severe(); await flush();
    assert.equal(failed.calls.publishes.length, 0); assert.equal(failed.controller.state().storageHealthy, false);
    assert.equal(failed.controller.state().status, failed.model.WearableStatus.FAILED);
    failed.config.save = true; await failed.advance(1); failed.severe(); await flush();
    assert.equal(failed.calls.publishes.length, 0);
    await failed.ready(); failed.severe(); await flush(); assert.equal(failed.calls.sends.length, 0);
    await failed.advance(9999); assert.equal(failed.calls.sends.length + failed.calls.publishes.length, 0);
    failed.severe(); await flush(); assert.equal(failed.calls.sends.length, 1);
  });

  await check('B save cancellation, route change and TTL timeout cannot publish after late flush', async () => {
    for (const cancel of [f => f.controller.setEnabled(false), f => f.controller.setRoute('wear-engine'),
      f => f.update({ foreground: false }), f => f.advance(5000)]) {
      const f = fixture(); await f.readyNotification(false); const gate = deferred(); f.config.flush = () => gate.promise;
      f.severe(); await flush(); assert.equal(f.calls.saved, 1); assert.equal(f.calls.publishes.length, 0);
      noWear(f); await cancel(f); gate.resolve(); await flush();
      assert.equal(f.calls.publishes.length, 0); assert.equal(f.calls.sends.length, 0);
      assert.ok(f.controller.state().cooldownRemainingMs > 0); await f.advance(60001);
      assert.equal(f.calls.publishes.length + f.calls.sends.length, 0);
      noWear(f, f.controller.state().route === 'wear-engine');
    }
  });

  await check('B publish timeout stays unknown and late success or failure cannot claim delivery or replay', async () => {
    for (const outcome of ['resolve', 'reject']) {
      const f = fixture(); await f.readyNotification(false); const gate = deferred(); f.config.publish = () => gate.promise;
      const testing = f.controller.test(); await flush(); assert.equal(f.calls.publishes.length, 1);
      await f.advance(5000); await testing;
      assert.equal(f.controller.state().status, f.model.WearableStatus.UNKNOWN);
      assert.equal(f.controller.state().busy, true); assert.equal(f.controller.state().canConfirmTest, true);
      assert.match(f.controller.state().testResult, /结果未知/);
      await f.advance(5000); assert.equal(f.controller.state().cooldownRemainingMs, 0);
      await f.controller.test(); f.severe(); await flush();
      assert.equal(f.controller.state().busy, true);
      assert.equal(f.calls.publishes.length, 1); assert.equal(f.calls.maxActive.publish, 1);
      if (outcome === 'resolve') gate.resolve(); else gate.reject(Object.assign(Error('late publish failure'), { code: 1600001 }));
      await flush(); assert.equal(f.controller.state().busy, false);
      assert.match(f.controller.state().testResult, /结果未知/);
      assert.equal(f.controller.state().confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
      assert.equal(f.calls.publishes.length, 1); noWear(f);
      f.config.publish = undefined; await f.controller.refresh(); await f.advance(1); f.severe(); await flush();
      assert.equal(f.calls.publishes.length, 2);
    }
  });

  await check('in-flight A and B sends share one SDK lock across route changes after timeout', async () => {
    for (const first of ['wear-engine', 'notification-sync']) {
      const f = fixture(); if (first === 'wear-engine') await f.ready(); else await f.readyNotification(false);
      const gate = deferred(); if (first === 'wear-engine') f.config.send = () => gate.promise;
      else f.config.publish = () => gate.promise;
      const testing = f.controller.test(); await flush(); await f.advance(5000); await testing;
      const route = first === 'wear-engine' ? 'notification-sync' : 'wear-engine';
      f.controller.setRoute(route); await f.advance(5000); await f.controller.refresh();
      assert.equal(f.controller.state().cooldownRemainingMs, 0);
      if (route === 'wear-engine') f.controller.select('route-a');
      await f.controller.test(); f.severe(); await flush();
      assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      assert.equal(f.controller.state().busy, true);
      gate.resolve(); await flush(); assert.equal(f.calls.sends.length + f.calls.publishes.length, 1);
      assert.match(f.controller.state().testResult, /结果未知/);
      await f.controller.refresh(); if (route === 'wear-engine') f.controller.select('route-a');
      await f.advance(1); f.severe(); await flush();
      assert.equal(f.calls.sends.length, 1); assert.equal(f.calls.publishes.length, 1);
      assert.ok((f.calls.maxActive.send || 0) <= 1); assert.ok((f.calls.maxActive.publish || 0) <= 1);
    }
  });

  await check('B outstanding publish and shared lock survive page close and B-to-A reattachment', async () => {
    const f = fixture(); await f.readyNotification(false); const gate = deferred(); f.config.publish = () => gate.promise;
    const testing = f.controller.test(); await flush(); await f.controller.close(); await testing;
    const local = await f.storage.loadWearable(f.context);
    f.controller.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
      state => f.storage.saveWearable(f.context, state), local,
      new f.notificationModule.PhoneNotificationReminderChannel(f.context));
    f.controller.setRoute('wear-engine'); f.update({ pageId: 2, foreground: true, guarding: false, testAllowed: true });
    f.controller.setEnabled(true); await f.advance(10000); await f.controller.refresh();
    assert.equal(f.controller.state().cooldownRemainingMs, 0);
    await f.controller.test(); assert.equal(f.calls.sends.length, 0); assert.equal(f.calls.publishes.length, 1);
    assert.equal(f.controller.state().busy, true); gate.resolve(); await flush();
    assert.match(f.controller.state().testResult, /结果未知/);
    await f.controller.refresh(); f.controller.select('route-a'); await f.controller.test();
    assert.equal(f.calls.sends.length, 1); assert.equal(f.calls.publishes.length, 1);
  });

  await check('B synchronous and async permission, slot and publish failures never fall back to A', async () => {
    for (const phase of ['getEnabled', 'getSlot', 'publish']) {
      for (const code of [1600004, 1600005, 1600008, 1600020, 1600001, 801]) {
        for (const sync of [false, true]) {
          const f = fixture(); await f.readyNotification(false);
          f.config[phase] = () => {
            const error = Object.assign(Error('notification failed'), { code });
            if (sync) throw error;
            return Promise.reject(error);
          };
          await f.controller.test();
          const state = f.controller.state();
          assert.equal(state.status, code === 801 ? f.model.WearableStatus.UNSUPPORTED :
            [1600004, 1600005].includes(code) ? f.model.WearableStatus.CONFIGURATION : f.model.WearableStatus.FAILED);
          assert.equal(state.busy, false); assert.match(state.detail, new RegExp(code.toString()));
          const sends = f.calls.publishes.length; await f.controller.test(); await f.advance(60001);
          assert.equal(f.calls.publishes.length, sends); assert.equal(sends, phase === 'publish' ? 1 : 0);
          assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
        }
      }
    }
  });

  await check('B API success remains unconfirmed until manual confirmation and preserves test route on disk', async () => {
    const f = fixture(); await f.readyNotification(false);
    await Promise.all([f.controller.test(), f.controller.test()]);
    assert.equal(f.calls.publishes.length, 1);
    let state = f.controller.state(); assert.match(state.testResult, /发布请求成功.*未确认/);
    assert.equal(state.confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
    assert.equal(state.testFeedback, ''); assert.equal(state.testModel, ''); assert.equal(state.testSoftwareVersion, '');
    assert.equal(state.diagnostics[0].action, -1); assert.equal(state.diagnostics[0].feedback, '');
    assert.equal(state.diagnostics[0].feedbackErrorCode, 0);
    noWear(f); f.controller.setRoute('wear-engine');
    for (const confirmation of [f.model.WearableTestConfirmation.DISPLAYED, f.model.WearableTestConfirmation.VIBRATED,
      f.model.WearableTestConfirmation.NOT_RECEIVED]) {
      f.controller.confirm(confirmation); await flush(); state = f.controller.state();
      assert.equal(state.confirmation, confirmation); assert.equal(state.testRoute, 'notification-sync');
      const loaded = await f.storage.loadWearable(f.context);
      assert.equal(loaded.confirmation, confirmation); assert.equal(loaded.testRoute, 'notification-sync');
    }
    assert.doesNotMatch(JSON.stringify([...f.values]), /当前|分，|randomId|route-a|route-b|frame|baseline/);
    assert.ok([...f.values.keys()].every(key => key.startsWith('wearable_local_'))); noWear(f, true);
  });

  await check('B clear and expiry cannot be resurrected by late publish completion', async () => {
    for (const clear of [true, false]) {
      const f = fixture(); await f.readyNotification(false); const gate = deferred(); f.config.publish = () => gate.promise;
      const testing = f.controller.test(); await flush(); await f.advance(5000); await testing;
      if (clear) {
        f.controller.clearDiagnostics(); assert.ok(f.controller.state().cooldownRemainingMs > 0);
      } else await f.advance(86400001);
      assert.equal(f.controller.state().testAt, 0); assert.equal(f.controller.state().diagnosticCount, 0);
      gate.resolve(); await flush();
      assert.equal(f.controller.state().testAt, 0); assert.equal(f.controller.state().diagnosticCount, 0);
      assert.equal((await f.storage.loadWearable(f.context)).testAt, 0);
      assert.equal(f.calls.publishes.length, 1); noWear(f);
    }
  });

  await check('local test route migrates safely and diagnostic route follows the actual sender', async () => {
    const f = fixture(); f.values.set('wearable_local_test_at', f.now());
    for (const route of [undefined, '', 'B', 4, true, 'notification-sync', 'wear-engine']) {
      if (route === undefined) f.values.delete('wearable_local_test_route');
      else f.values.set('wearable_local_test_route', route);
      assert.equal((await f.storage.loadWearable(f.context)).testRoute,
        route === 'notification-sync' ? route : 'wear-engine');
    }
    await f.readyNotification(false); await f.controller.test(); await f.advance(10001); await f.ready();
    await f.controller.test(); const diagnostics = f.controller.state().diagnostics;
    assert.deepEqual(Array.from(diagnostics, item => item.route), ['wear-engine', 'notification-sync']);
    assert.equal(f.controller.state().testRoute, 'wear-engine');
    assert.equal((await f.storage.loadWearable(f.context)).testRoute, 'wear-engine');
  });

  await check('multiple confirmed B tests survive restart with independent event IDs and formal records', async () => {
    const f = fixture({ configured: false, supported: false }); await f.readyNotification(false);
    const confirmations = [f.model.WearableTestConfirmation.VIBRATED, f.model.WearableTestConfirmation.DISPLAYED,
      f.model.WearableTestConfirmation.NOT_RECEIVED];
    for (let i = 0; i < confirmations.length; i++) {
      if (i) await f.advance(10000);
      await f.controller.test(); f.controller.confirm(confirmations[i]); await flush();
    }
    await f.advance(10000); f.severe(42); await flush();
    const local = await f.storage.loadWearable(f.context);
    assert.equal(local.diagnostics.length, 4); assert.equal(local.confirmation, confirmations[2]);
    assert.equal(new Set(local.diagnostics.map(item => item.eventId)).size, 4);
    const saved = Array.from(local.diagnostics);
    assert.equal(saved[0].isTest, false); assert.equal(saved[0].confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
    assert.deepEqual(saved.slice(1).map(item => item.confirmation), confirmations.slice().reverse());
    const rebuilt = new f.serviceModule.WearableReminderController(f.clock, new f.model.WearableReminderPolicy());
    rebuilt.attach(new f.channelModule.WearEngineNotificationChannel(f.context),
      state => f.storage.saveWearable(f.context, state), local,
      new f.notificationModule.PhoneNotificationReminderChannel(f.context));
    assert.equal(rebuilt.state().diagnosticCount, 4);
    assert.deepEqual(normalize(rebuilt.state().diagnostics), normalize(local.diagnostics));
    const snapshot = rebuilt.state(); snapshot.diagnostics[0].result = 'mutated';
    assert.notEqual(rebuilt.state().diagnostics[0].result, 'mutated');
    const runtime = Object.assign(new f.model.WearableRuntime(), { foreground: true, pageId: 2, testAllowed: true });
    const candidate = new f.model.WearableReminderPolicy().test(runtime, 1, f.now(), f.uptime());
    assert.ok(!saved.some(item => item.eventId === candidate.eventId)); noWear(f);
  });

  await check('legacy device confirmation migrates once without changing route, confirmation or cooldown', async () => {
    const f = fixture();
    f.values.set('wearable_local_attempt', f.now()); f.values.set('wearable_local_uptime', f.uptime());
    f.values.set('wearable_local_test_at', f.now()); f.values.set('wearable_local_test_route', 'notification-sync');
    f.values.set('wearable_local_test_result', '手机通知发布请求成功；腕上送达未确认');
    f.values.set('wearable_local_confirmation', f.model.WearableTestConfirmation.VIBRATED);
    let local = await f.storage.loadWearable(f.context);
    assert.equal(local.testSubmitted, true); assert.equal(local.diagnostics.length, 1);
    assert.equal(local.diagnostics[0].confirmation, f.model.WearableTestConfirmation.VIBRATED);
    assert.equal(local.diagnostics[0].eventId, 'legacy-test:' + f.now());
    assert.equal(local.diagnostics[0].route, 'notification-sync');
    await f.storage.saveWearable(f.context, local); local = await f.storage.loadWearable(f.context);
    assert.equal(local.diagnostics.length, 1); assert.equal(local.confirmation, f.model.WearableTestConfirmation.VIBRATED);
    f.controller.attach(f.channel, state => f.storage.saveWearable(f.context, state), local, f.notificationChannel);
    assert.equal(f.controller.state().cooldownRemainingMs, 10000);
    assert.equal(f.controller.state().canConfirmTest, true);
    assert.equal(f.calls.publishes.length, 0); assert.equal(f.calls.sends.length, 0);
  });

  await check('failed B preflight replaces the latest test without reusing the previous confirmed success', async () => {
    for (const phase of ['permission', 'slot', 'storage']) {
      const f = fixture(); await f.readyNotification(false); await f.controller.test();
      f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED); await flush();
      const previousAt = f.controller.state().testAt; await f.advance(10000);
      if (phase === 'permission') f.config.notificationEnabled = false;
      else if (phase === 'slot') f.config.slotEnabled = false;
      else f.config.save = false;
      await f.controller.test(); const state = f.controller.state();
      assert.equal(f.calls.publishes.length, 1);
      assert.ok(state.testAt > previousAt); assert.match(state.testResult, /未提交/);
      assert.equal(state.confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
      assert.equal(state.canConfirmTest, false); assert.equal(state.diagnosticCount, 2);
      assert.equal(state.diagnostics[0].submitted, false);
      assert.equal(state.diagnostics[1].confirmation, f.model.WearableTestConfirmation.VIBRATED);
      f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED);
      assert.equal(f.controller.state().confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
      if (phase !== 'storage') {
        const local = await f.storage.loadWearable(f.context);
        assert.equal(local.testSubmitted, false); assert.equal(local.diagnostics.length, 2);
        assert.equal(local.confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
        assert.equal(f.controller.state().cooldownRemainingMs, 0);
      } else assert.equal(state.storageHealthy, false);
      noWear(f);
    }
  });

  await check('B permission failures survive repeated background transitions without silent retries', async () => {
    for (const state of ['permission', 'publish', 'unprepared']) {
      const f = fixture();
      if (state !== 'unprepared') await f.readyNotification(false);
      else f.controller.setEnabled(true);
      if (state === 'permission') { f.config.notificationEnabled = false; await f.controller.refresh(); }
      if (state === 'publish') { f.config.publish = () => Promise.reject(Error('publish failed')); await f.controller.test(); }
      const before = f.controller.state(); const checks = f.calls.enabled, slots = f.calls.slots;
      for (let i = 0; i < 2; i++) {
        f.update({ foreground: false }); f.update({ foreground: false }); f.update({ foreground: true });
        assert.equal(f.controller.state().status, before.status); assert.equal(f.controller.state().detail, before.detail);
      }
      assert.equal(f.calls.enabled, checks); assert.equal(f.calls.slots, slots);
      assert.equal(f.calls.publishes.length, state === 'publish' ? 1 : 0); noWear(f);
    }
  });

  await check('persisted diagnostic history bounds, sanitizes, clears and cannot expose payload data', async () => {
    const f = fixture(); await f.readyNotification(false); await f.controller.test();
    f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED); await flush();
    const base = normalize((await f.storage.loadWearable(f.context)).diagnostics[0]);
    const entries = Array.from({ length: 110 }, (_, i) => ({ ...base, eventId: 'history-' + i,
      timestamp: f.now() - i, extra: 'private-notification-payload', result: '中'.repeat(200) }));
    entries[0] = null; entries[1] = {}; entries[2].timestamp = f.now() + 1;
    entries[3].timestamp = f.now() - 86400001; entries[4].submitted = false;
    f.values.set('wearable_local_test_at', 0); f.values.set('wearable_local_diagnostics', JSON.stringify(entries));
    let local = await f.storage.loadWearable(f.context);
    assert.equal(local.diagnostics.length, 96); assert.equal(local.diagnostics[0].submitted, false);
    assert.equal(local.diagnostics[0].confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
    assert.ok(local.diagnostics.every(item => Buffer.byteLength(item.result) <= 120));
    await f.storage.saveWearable(f.context, local);
    assert.doesNotMatch(f.values.get('wearable_local_diagnostics'), /private-notification-payload|extra/);
    f.controller.attach(f.channel, state => f.storage.saveWearable(f.context, state), local, f.notificationChannel);
    const remaining = f.controller.state().cooldownRemainingMs;
    f.controller.clearDiagnostics(); await flush(); local = await f.storage.loadWearable(f.context);
    assert.equal(local.diagnostics.length, 0); assert.equal(local.testAt, 0);
    assert.equal(f.controller.state().cooldownRemainingMs, remaining);
    f.values.set('wearable_local_diagnostics', '{broken');
    assert.equal((await f.storage.loadWearable(f.context)).diagnostics.length, 0);
    f.values.set('wearable_local_diagnostics', 'x'.repeat(131073));
    assert.equal((await f.storage.loadWearable(f.context)).diagnostics.length, 0);
  });

  await check('persisted diagnostic snapshots are immutable while queued and expiry cannot revive history', async () => {
    const f = fixture(); const gate = deferred(); f.config.flush = () => gate.promise;
    const local = new f.model.WearableLocalState(), diagnostic = new f.model.WearableDiagnostic();
    diagnostic.eventId = 'snapshot'; diagnostic.timestamp = f.now(); diagnostic.route = 'notification-sync';
    diagnostic.result = 'first'; local.diagnostics.push(diagnostic);
    const pending = f.storage.saveWearable(f.context, local); diagnostic.result = 'mutated'; await flush();
    gate.resolve(); await pending; f.config.flush = undefined;
    assert.equal((await f.storage.loadWearable(f.context)).diagnostics[0].result, 'first');
    await f.advance(86400001);
    assert.equal((await f.storage.loadWearable(f.context)).diagnostics.length, 0);
    noNotificationMutation(f);
  });

  await check('formal B startup uses saved settings without testing and keeps experimental tools collapsed', async () => {
    const f = startupFixture(); const initializing = f.p.initializeWearable(1), loading = f.p.loadData(1);
    f.settings.resolve(); f.initialization.resolve(); await initializing; await loading; await flush();
    assert.equal(f.controller.state().route, 'notification-sync');
    assert.equal(f.controller.state().status, f.model.WearableStatus.READY);
    assert.equal(f.calls.publishes.length, 0); assert.equal(f.controller.state().testAt, 0);
    assert.equal(f.calls.authorizations.length, 0); assert.equal(f.calls.addedSlots.length, 0); noWear(f);
    assert.doesNotMatch(pageMethod('SettingsPage'), /NotificationSyncTestPanel\(/);
    assert.match(pageMethod('DeveloperDebugPanel'), /if \(this\.showDebugPanel\)[\s\S]*NotificationSyncTestPanel\(/);
    const panel = fs.readFileSync(path.join(sourceRoot, 'components/WearableReminderPanel.ets'), 'utf8');
    assert.match(panel, /reminderRoute: WearableReminderRoute = WearableReminderRoute\.NOTIFICATION_SYNC/);
    assert.match(panel, /showAdvancedChannels: boolean = false/);
    assert.match(panel, /showTestRecords: boolean = false/);
    assert.match(panel, /if \(this\.showAdvancedChannels\)[\s\S]*WearableReminderRoute\.WEAR_ENGINE/);
    assert.match(panel, /if \(!this\.showTestRecords\)[\s\S]*wearable-test-summary/);
    assert.match(panel, /if \(this\.showTestRecords\)[\s\S]*wearable-reminder-test/);
    assert.match(panel, /diagnostic\.confirmation/);
    await f.service.destroy(f.pageId);
  });

  await check('clearing history cancels pre-submit B checks and saves without resurrecting a test', async () => {
    for (const phase of ['permission', 'slot', 'storage']) {
      for (const outcome of ['resolve', 'reject']) {
        const f = fixture(); await f.readyNotification(false); await f.controller.test();
        f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED); await flush(); await f.advance(10000);
        const gate = deferred(); let saves = 0;
        if (phase === 'permission') f.config.getEnabled = () => gate.promise;
        else if (phase === 'slot') f.config.getSlot = () => gate.promise;
        else f.config.flush = () => ++saves === 1 ? gate.promise : Promise.resolve();
        const testing = f.controller.test(); await flush();
        assert.equal(f.controller.state().busy, true); f.controller.clearDiagnostics();
        const cooldown = f.controller.state().cooldownRemainingMs;
        if (outcome === 'resolve') gate.resolve(phase === 'permission' ? true : { enabled: true });
        else gate.reject(Error('old operation rejected'));
        await testing; await flush();
        assert.equal(f.calls.publishes.length, 1); assert.equal(f.controller.state().testAt, 0);
        assert.equal(f.controller.state().diagnosticCount, 0); assert.equal(f.controller.state().canConfirmTest, false);
        assert.equal(f.controller.state().cooldownRemainingMs, cooldown);
        const local = await f.storage.loadWearable(f.context);
        assert.equal(local.testAt, 0); assert.equal(local.diagnostics.length, 0); noWear(f);
      }
    }
  });

  await check('A target recheck failure records an unsubmitted test instead of retaining old success', async () => {
    for (const phase of ['disconnected', 'new-route', 'unsupported']) {
      const f = fixture(); await f.ready(); await f.controller.test();
      f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED); await flush(); await f.advance(10000);
      f.config.devices = phase === 'disconnected' ? [] :
        [f.device(phase === 'new-route' ? 'route-new' : 'route-a', 'target', phase !== 'unsupported')];
      await f.controller.test(); const state = f.controller.state();
      assert.equal(f.calls.sends.length, 1); assert.match(state.testResult, /未提交/);
      assert.equal(state.confirmation, f.model.WearableTestConfirmation.UNCONFIRMED);
      assert.equal(state.canConfirmTest, false); assert.equal(state.diagnostics[0].submitted, false);
      assert.equal(state.diagnostics[1].confirmation, f.model.WearableTestConfirmation.VIBRATED);
      assert.equal(state.cooldownRemainingMs, 0);
      const local = await f.storage.loadWearable(f.context);
      assert.equal(local.testSubmitted, false); assert.equal(local.diagnostics.length, 2);
      noNotificationMutation(f);
    }
  });

  await check('reload does not resurrect a modern test evicted by 100 newer formal diagnostics', async () => {
    const f = fixture(); await f.readyNotification(false); await f.controller.test();
    f.controller.confirm(f.model.WearableTestConfirmation.VIBRATED); await flush();
    for (let i = 0; i < 100; i++) { await f.advance(10000); f.severe(); await flush(); }
    const before = f.controller.state(); assert.equal(before.diagnosticCount, 100);
    assert.ok(before.diagnostics.every(item => !item.isTest));
    const raw = JSON.parse(f.values.get('wearable_local_diagnostics'));
    assert.equal(raw.length, 100); assert.ok(raw.every(item => !item.isTest));
    let local = await f.storage.loadWearable(f.context);
    assert.equal(local.diagnostics.length, 100); assert.ok(local.diagnostics.every(item => !item.isTest));
    assert.equal(local.confirmation, f.model.WearableTestConfirmation.VIBRATED);
    assert.deepEqual(normalize(local.diagnostics), raw);
    const modernId = local.testEventId;
    await f.storage.saveWearable(f.context, local); local = await f.storage.loadWearable(f.context);
    assert.equal(local.testEventId, modernId); assert.deepEqual(normalize(local.diagnostics), raw);
    f.values.delete('wearable_local_test_event');
    const legacy = await f.storage.loadWearable(f.context);
    assert.equal(legacy.diagnostics.length, 100); assert.ok(legacy.diagnostics.every(item => !item.isTest));
    assert.equal(legacy.diagnostics[0].timestamp, f.now()); noWear(f);
  });

  await check('static boundaries: no fake client configuration, permissions, fallback or camera changes', async () => {
    const manifest = fs.readFileSync(path.join(root, 'entry/src/main/module.json5'), 'utf8');
    assert.doesNotMatch(manifest, /client_id|BLUETOOTH|HEALTH|DISTRIBUTED|NOTIFICATION_CONTROLLER/);
    const channel = fs.readFileSync(path.join(sourceRoot, 'services/WearEngineNotificationChannel.ets'), 'utf8');
    assert.doesNotMatch(channel, /getSerialNumber|requestAuthorization|healthStore|SensorType|sendMessage/);
    const service = fs.readFileSync(path.join(sourceRoot, 'services/WearableReminderService.ets'), 'utf8');
    assert.doesNotMatch(service, /SessionRecord|appendRecord|captureFrame|evaluatePosture|PHONE_VIBRATION|notificationManager/);
    assert.doesNotMatch(pageMethod('testWearableReminder'), /captureFrame|calibrate|appendRecord|persistData/);
    const dispatcher = pageMethod('dispatchLowScoreFeedback');
    assert.ok(dispatcher.indexOf('.submit(') < dispatcher.indexOf('if (!decision.vibrate)'));
    assert.doesNotMatch(pageMethod('applyLowScoreDecision') + pageMethod('scheduleReminderExpiry'), /\.submit\(/);
    assert.match(pageMethod('SettingsPage'), /WearableReminderPanel\(/);
    assert.doesNotMatch(pageMethod('GuardPage'), /WearableReminderPanel\(/);
    const notification = fs.readFileSync(path.join(sourceRoot, 'services/PhoneNotificationReminderChannel.ets'), 'utf8');
    assert.doesNotMatch(notification, /@kit\.WearEngine|wearEngine\.|getConnectedDevices|onAction|getActiveNotifications|cancelAll|SessionRecord|appendRecord/);
    assert.doesNotMatch(notification, /NotificationSyncTestService|NOTIFICATION_SYNC_TEST_ID|29001/);
    assert.doesNotMatch(pageMethod('prepareNotificationSync') + pageMethod('toggleWearableRoute'),
      /captureFrame|calibrate|appendRecord|requestEnableNotification|addSlot|publish\(/);
  });
}

main().then(() => {
  assert.equal(failures.length, 0, failures.length + '/' + checks + ' wearable groups failed: ' +
    failures.map(item => item.name).join('; '));
  console.log('Wearable offline regression passed: ' + checks + ' groups; no real device calls.');
})
  .catch(error => { console.error(error); process.exitCode = 1; });
