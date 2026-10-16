import { common } from '@kit.AbilityKit';
import { systemDateTime } from '@kit.BasicServicesKit';
import { LowScoreDecision, LowScoreLevel } from '../models/LowScoreReminder';
import { WearableReminderRoute } from '../models/PostureTypes';
import {
  WEARABLE_DIAGNOSTIC_TTL_MS, WEARABLE_REMINDER_POLICY, copyWearableDiagnostic, WearableCandidate, WearableDeviceChoice,
  WearableDiagnostic, WearableLocalState,
  WearableReminderPolicy, WearableRuntime, WearableStatus, WearableTestConfirmation, WearableViewState
} from '../models/WearableReminderPolicy';
import { PostureSessionStore } from './PostureSessionStore';
import { WearableChannelError, WearableNotificationChannel, WearEngineNotificationChannel } from './WearEngineNotificationChannel';
import { PhoneNotificationReminderChannel } from './PhoneNotificationReminderChannel';

export interface WearableClock {
  wall(): number;
  uptime(): number;
}

class DeviceWearableClock implements WearableClock {
  wall(): number {
    return Date.now();
  }

  uptime(): number {
    try {
      return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
    } catch (error) {
      return Number.NaN;
    }
  }
}

class WearableOperation {
  active: boolean = true;
}

class WearableWait {
  id: number = -1;
  cancel: () => void = (): void => {};
}

export class WearableReminderController {
  private clock: WearableClock;
  private policy: WearableReminderPolicy;
  private channel: WearableNotificationChannel | undefined = undefined;
  private notificationChannel: PhoneNotificationReminderChannel | undefined = undefined;
  private route: WearableReminderRoute = WearableReminderRoute.NOTIFICATION_SYNC;
  private notificationReady: boolean = false;
  private notificationCheckNeeded: boolean = true;
  private local: WearableLocalState = new WearableLocalState();
  private view: WearableViewState = new WearableViewState();
  private diagnostics: WearableDiagnostic[] = [];
  private runtime: WearableRuntime = new WearableRuntime();
  private enabled: boolean = false;
  private loaded: boolean = false;
  private generation: number = 0;
  private pending: boolean = false;
  private sdkInFlight: boolean = false;
  private testPending: boolean = false;
  private discoveryId: number = 0;
  private selected: WearableDeviceChoice | undefined = undefined;
  private waits: Set<WearableWait> = new Set<WearableWait>();
  private lastTestEvent: string = '';
  private cooldownTimer: number = -1;
  private suspendedStatus: WearableStatus = WearableStatus.OFF;
  private suspendedDetail: string = '';
  private hasSuspendedView: boolean = false;
  private listener: (state: WearableViewState) => void = (): void => {};
  private save: (state: WearableLocalState) => Promise<boolean> =
    async (): Promise<boolean> => false;

  constructor(clock: WearableClock, policy: WearableReminderPolicy) {
    this.clock = clock;
    this.policy = policy;
  }

  attach(channel: WearableNotificationChannel, save: (state: WearableLocalState) => Promise<boolean>,
    local: WearableLocalState, notificationChannel: PhoneNotificationReminderChannel | undefined = undefined): void {
    this.invalidate();
    this.channel = channel;
    this.notificationChannel = notificationChannel;
    this.notificationReady = false;
    this.notificationCheckNeeded = true;
    this.save = save;
    this.local = local;
    this.lastTestEvent = '';
    this.diagnostics = local.diagnostics.map((item: WearableDiagnostic): WearableDiagnostic => copyWearableDiagnostic(item));
    this.hasSuspendedView = false;
    this.selected = undefined;
    this.view.devices = [];
    this.policy.restore(local.lastAttemptAt, local.lastAttemptUptime, this.clock.wall(), this.clock.uptime());
    this.loaded = true;
    this.publish();
  }

  observe(listener: (state: WearableViewState) => void): void {
    this.listener = listener;
    this.publish();
  }

  unobserve(): void {
    this.listener = (): void => {};
  }

  setEnabled(enabled: boolean): void {
    if (enabled !== this.enabled) {
      this.invalidate();
      this.selected = undefined;
      this.view.devices = [];
      this.notificationReady = false;
      this.notificationCheckNeeded = true;
      this.enabled = enabled;
      this.hasSuspendedView = false;
      this.view.status = enabled ? WearableStatus.CONFIGURATION : WearableStatus.OFF;
      this.view.detail = enabled ? this.route === WearableReminderRoute.NOTIFICATION_SYNC ?
        '已选普通通知同步；请先准备手机通知，并在运动健康中开启坐直了和亮屏时多设备提醒' :
        '需有效Client ID、服务审批和用户选择目标设备；不会自动发送测试' :
        '腕上提醒已关闭，手机提醒保持原样';
    }
    this.publish();
  }

  setRoute(route: WearableReminderRoute): void {
    const next = route === WearableReminderRoute.WEAR_ENGINE ? route : WearableReminderRoute.NOTIFICATION_SYNC;
    if (next === this.route) {
      return;
    }
    this.invalidate();
    this.route = next;
    this.hasSuspendedView = false;
    this.notificationReady = false;
    this.notificationCheckNeeded = true;
    this.selected = undefined;
    this.view.devices = [];
    this.view.status = this.enabled ? WearableStatus.CONFIGURATION : WearableStatus.OFF;
    this.view.detail = next === WearableReminderRoute.NOTIFICATION_SYNC ?
      '已选普通通知同步；请先准备手机通知，切换只影响新事件，不自动发送或补发' :
      '已选Wear Engine；请刷新并明确选择设备，切换只影响新事件，不自动发送或补发';
    this.publish();
  }

  update(runtime: WearableRuntime): void {
    const previous = this.runtime;
    this.runtime = runtime;
    if (!runtime.foreground || runtime.calibrating || runtime.pageId !== previous.pageId ||
      runtime.sessionId !== previous.sessionId || runtime.guarding !== previous.guarding ||
      runtime.realSource !== previous.realSource || previous.testAllowed && !runtime.testAllowed || runtime.guarding &&
      (runtime.level !== LowScoreLevel.SEVERE || runtime.score >= 50 || runtime.expiresAt <= this.clock.wall())) {
      this.invalidate();
    }
    if (!runtime.foreground) {
      this.selected = undefined;
      this.view.devices = [];
      if (this.enabled) {
        if (!this.hasSuspendedView) {
          this.suspendedStatus = this.view.status;
          this.suspendedDetail = this.view.detail;
          this.hasSuspendedView = true;
        }
        this.view.status = WearableStatus.DISCONNECTED;
        this.view.detail = '应用已离开前台；待办已取消，已交系统的通知无法保证撤回';
      }
    } else if (!previous.foreground && this.enabled && this.route === WearableReminderRoute.NOTIFICATION_SYNC) {
      if (this.sdkInFlight) {
        this.view.status = WearableStatus.UNKNOWN;
        this.view.detail = '仍有已交系统的通知等待结果；不并发发送或自动补发';
      } else if (this.notificationReady) {
        this.view.status = WearableStatus.READY;
        this.view.detail = '手机通知已准备；手环连接和亮屏同步由运动健康设置决定，等待新的严重低分';
      } else if (this.hasSuspendedView) {
        this.view.status = this.suspendedStatus === WearableStatus.CHECKING ||
          this.suspendedStatus === WearableStatus.SENDING ? WearableStatus.CONFIGURATION : this.suspendedStatus;
        this.view.detail = this.suspendedDetail;
      } else {
        this.view.status = WearableStatus.CONFIGURATION;
        this.view.detail = '请检查或准备手机通知；只处理之后的新严重低分，不补发历史通知';
      }
      this.hasSuspendedView = false;
    }
    this.publish();
  }

  suspend(): void {
    const runtime = new WearableRuntime();
    runtime.pageId = this.runtime.pageId;
    runtime.sessionId = this.runtime.sessionId;
    this.update(runtime);
  }

  invalidate(): void {
    const wasPending = this.pending;
    this.generation += 1;
    this.discoveryId += 1;
    this.pending = false;
    this.testPending = false;
    if (this.cooldownTimer >= 0) {
      clearTimeout(this.cooldownTimer);
      this.cooldownTimer = -1;
    }
    this.waits.forEach((wait: WearableWait): void => {
      clearTimeout(wait.id);
      wait.cancel();
    });
    this.waits.clear();
    if (wasPending && this.enabled) {
      this.view.status = this.sdkInFlight ? WearableStatus.UNKNOWN : this.idleStatus();
      this.view.detail = this.sdkInFlight ? '本地待办已取消；已交系统的通知结果未知，不能保证撤回或重发' :
        '未提交的待办已取消；不排队补发，正式提醒等待新的有效严重低分';
    }
  }

  async refresh(): Promise<void> {
    if (this.route === WearableReminderRoute.NOTIFICATION_SYNC) {
      await this.refreshNotificationSync(false);
      return;
    }
    const channel = this.channel;
    if (!this.enabled || !this.loaded || channel === undefined || !this.runtime.foreground ||
      this.runtime.calibrating || this.pending || this.sdkInFlight) {
      return;
    }
    if (!channel.configured()) {
      this.view.status = WearableStatus.CONFIGURATION;
      this.view.detail = '尚未配置Wear Engine Client ID；请先完成设备基础信息与消息通知服务审批';
      this.publish();
      return;
    }
    if (!channel.supported()) {
      this.view.status = WearableStatus.UNSUPPORTED;
      this.view.detail = '手机不提供Wear Engine能力；手机守护仍可用';
      this.publish();
      return;
    }
    const generation = this.generation;
    const discovery = ++this.discoveryId;
    const operation = new WearableOperation();
    const current = (): boolean => generation === this.generation && discovery === this.discoveryId &&
      operation.active && this.enabled && this.runtime.foreground && !this.runtime.calibrating;
    this.pending = true;
    this.view.status = WearableStatus.CHECKING;
    this.publish();
    try {
      channel.listen((): void => { this.serviceDied(); });
      const devices = await this.bounded<WearableDeviceChoice[]>(channel.discover(current), operation, 5000);
      if (!current()) {
        return;
      }
      this.applyDevices(devices);
      this.view.status = devices.length === 0 ? WearableStatus.DISCONNECTED :
        this.selected === undefined ? WearableStatus.SELECT :
          this.selected.supported ? WearableStatus.READY : WearableStatus.UNSUPPORTED;
      this.view.detail = devices.length === 0 ? '运动健康未返回在线设备，请检查配对与连接' :
        this.selected === undefined ? '请明确选择一台设备；不会默认发给第一台' : '已复核当前连接，等待新的有效严重低分';
    } catch (error) {
      if (generation === this.generation && discovery === this.discoveryId) {
        this.fail(error instanceof WearableChannelError ? error :
          new WearableChannelError(0, WearableStatus.FAILED, '设备查询失败，请核对服务准备'));
      }
    } finally {
      operation.active = false;
      if (generation === this.generation && discovery === this.discoveryId) {
        this.pending = false;
        this.publish();
      }
    }
  }

  async prepareNotificationSync(): Promise<void> {
    if (this.route !== WearableReminderRoute.NOTIFICATION_SYNC || !this.runtime.testAllowed ||
      this.runtime.guarding) {
      return;
    }
    await this.refreshNotificationSync(true);
  }

  private async refreshNotificationSync(authorize: boolean): Promise<void> {
    const channel = this.notificationChannel;
    if (!this.enabled || !this.loaded || channel === undefined || !this.runtime.foreground ||
      this.runtime.calibrating || this.pending || this.sdkInFlight) {
      return;
    }
    const generation = this.generation;
    const discovery = ++this.discoveryId;
    const operation = new WearableOperation();
    const started = this.clock.uptime();
    const timeoutMs = authorize ? 60000 : 5000;
    const current = (): boolean => operation.active && generation === this.generation &&
      discovery === this.discoveryId && this.enabled && this.runtime.foreground && !this.runtime.calibrating &&
      this.route === WearableReminderRoute.NOTIFICATION_SYNC &&
      Number.isFinite(started) && this.clock.uptime() >= started && this.clock.uptime() < started + timeoutMs &&
      (!authorize || this.runtime.testAllowed && !this.runtime.guarding);
    this.pending = true;
    this.notificationCheckNeeded = true;
    this.view.status = WearableStatus.CHECKING;
    this.view.detail = authorize ? '正在准备手机通知；此步骤不发布通知' : '正在检查手机通知权限与服务提醒渠道';
    this.publish();
    try {
      await this.bounded<void>(authorize ? channel.prepare(current) : channel.check(current), operation,
        timeoutMs);
      if (!current()) {
        return;
      }
      this.notificationReady = true;
      this.notificationCheckNeeded = false;
      this.view.status = WearableStatus.READY;
      this.view.detail = '手机通知已准备；请在运动健康开启坐直了和多设备提醒，实际腕上送达仍待确认';
    } catch (error) {
      if (generation === this.generation && discovery === this.discoveryId) {
        this.fail(error instanceof WearableChannelError ? error :
          new WearableChannelError(0, WearableStatus.FAILED, '手机通知准备失败，请手动重试准备，不自动发送'));
      }
    } finally {
      operation.active = false;
      if (generation === this.generation && discovery === this.discoveryId) {
        this.pending = false;
        this.publish();
      }
    }
  }

  select(routeId: string): void {
    if (!this.enabled || !this.runtime.foreground || this.route !== WearableReminderRoute.WEAR_ENGINE) {
      return;
    }
    const selected = this.view.devices.find((device: WearableDeviceChoice): boolean => device.routeId === routeId);
    this.invalidate();
    this.selected = selected;
    this.view.status = selected === undefined ? WearableStatus.SELECT :
      selected.supported ? WearableStatus.READY : WearableStatus.UNSUPPORTED;
    this.view.detail = selected?.supported ? '仅发送到当前明确选中的设备；重连标识改变后需重选' :
      '该目标不支持Wear Engine直发通知；不会自动切换其他通道';
    this.publish();
  }

  submit(decision: LowScoreDecision, score: number, timestamp: number): void {
    const candidate = this.policy.create(decision, score, timestamp, this.runtime, this.generation,
      this.clock.wall(), this.clock.uptime());
    if (candidate !== undefined && this.ready(true)) {
      candidate.route = this.route;
      this.dispatch(candidate).catch((): void => {});
    }
  }

  async test(): Promise<void> {
    if (!this.runtime.testAllowed || this.runtime.guarding || this.runtime.calibrating || !this.ready()) {
      return;
    }
    const candidate = this.policy.test(this.runtime, this.generation, this.clock.wall(), this.clock.uptime());
    candidate.route = this.route;
    await this.dispatch(candidate);
  }

  confirm(result: WearableTestConfirmation): void {
    if (this.local.testAt <= 0 || this.local.testAt > this.clock.wall() ||
      this.clock.wall() - this.local.testAt > WEARABLE_DIAGNOSTIC_TTL_MS || this.testPending ||
      !this.local.testSubmitted) {
      return;
    }
    this.local.confirmation = result;
    const diagnostic = this.diagnostics.find((item: WearableDiagnostic): boolean =>
      item.eventId === this.local.testEventId);
    if (diagnostic !== undefined) {
      diagnostic.confirmation = result;
    }
    this.persist();
    this.publish();
  }

  clearDiagnostics(): void {
    this.invalidate();
    this.diagnostics = [];
    this.lastTestEvent = '';
    this.local.testAt = 0;
    this.local.testEventId = '';
    this.local.testSubmitted = false;
    this.local.testResult = '';
    this.local.testFeedback = '';
    this.local.confirmation = WearableTestConfirmation.UNCONFIRMED;
    this.local.model = '';
    this.local.softwareVersion = '';
    this.persist();
    this.publish();
  }

  async close(): Promise<void> {
    this.invalidate();
    if (this.sdkInFlight && this.lastTestEvent.length > 0) {
      this.local.testResult = '请求已交系统，页面已关闭；结果未知，不自动重发';
      this.persist();
    }
    this.lastTestEvent = '';
    const channel = this.channel;
    const notificationChannel = this.notificationChannel;
    this.channel = undefined;
    this.notificationChannel = undefined;
    this.notificationReady = false;
    this.notificationCheckNeeded = false;
    this.selected = undefined;
    this.view.devices = [];
    this.loaded = false;
    this.enabled = false;
    this.runtime = new WearableRuntime();
    this.view.status = WearableStatus.OFF;
    this.unobserve();
    try {
      await channel?.close();
      await notificationChannel?.close();
    } catch (error) {
    }
  }

  state(): WearableViewState {
    this.prune();
    const result = new WearableViewState();
    result.route = this.route;
    result.status = this.view.status;
    result.detail = this.view.detail;
    result.devices = this.view.devices.slice();
    result.selectedId = this.selected?.routeId ?? '';
    result.selectedName = this.selected?.name ?? '';
    result.busy = this.pending || this.sdkInFlight;
    result.cooldownRemainingMs = this.policy.remaining(this.clock.uptime());
    result.storageHealthy = this.view.storageHealthy;
    result.canTest = this.ready() && this.runtime.testAllowed && !this.runtime.guarding && !this.runtime.calibrating &&
      result.cooldownRemainingMs === 0;
    result.canConfirmTest = this.local.testAt > 0 && this.local.testSubmitted && !this.testPending;
    result.testAt = this.local.testAt;
    result.testRoute = this.local.testRoute;
    result.testResult = this.local.testResult;
    result.testFeedback = this.local.testFeedback;
    result.testModel = this.local.model;
    result.testSoftwareVersion = this.local.softwareVersion;
    result.confirmation = this.local.confirmation;
    result.diagnosticCount = this.diagnostics.length;
    result.diagnostics = this.diagnostics.slice(0, 5).map((item: WearableDiagnostic): WearableDiagnostic =>
      copyWearableDiagnostic(item));
    return result;
  }

  private activeChannel(): WearableNotificationChannel | undefined {
    return this.route === WearableReminderRoute.NOTIFICATION_SYNC ? this.notificationChannel : this.channel;
  }

  private idleStatus(): WearableStatus {
    return this.route === WearableReminderRoute.NOTIFICATION_SYNC ?
      this.notificationReady ? WearableStatus.READY : WearableStatus.CONFIGURATION :
      this.selected === undefined ? WearableStatus.SELECT :
        this.selected.supported ? WearableStatus.READY : WearableStatus.UNSUPPORTED;
  }

  private ready(allowNotificationCheck: boolean = false): boolean {
    const channel = this.activeChannel();
    return this.enabled && this.loaded && this.runtime.foreground && !this.runtime.calibrating &&
      channel !== undefined && !this.pending && !this.sdkInFlight && channel.configured() && channel.supported() &&
      (this.route === WearableReminderRoute.NOTIFICATION_SYNC ?
        this.notificationReady || allowNotificationCheck && this.notificationCheckNeeded :
        this.selected !== undefined && this.selected.supported);
  }

  private sameContext(candidate: WearableCandidate): boolean {
    const runtime = this.runtime;
    return this.enabled && this.loaded && runtime.foreground && !runtime.calibrating &&
      candidate.route === this.route && candidate.generation === this.generation && candidate.pageId === runtime.pageId &&
      candidate.sessionId === runtime.sessionId && (candidate.isTest ? runtime.testAllowed && !runtime.guarding :
      runtime.guarding && runtime.realSource && runtime.level === LowScoreLevel.SEVERE &&
      runtime.score < 50 && runtime.expiresAt > this.clock.wall());
  }

  private current(candidate: WearableCandidate): boolean {
    const uptime = this.clock.uptime();
    const wall = this.clock.wall();
    return this.sameContext(candidate) && Number.isFinite(uptime) && Number.isFinite(wall) &&
      uptime >= candidate.createdUptime && uptime < candidate.deadlineUptime &&
      wall >= candidate.sampleTimestamp && wall < candidate.expiresAt;
  }

  private async dispatch(candidate: WearableCandidate): Promise<void> {
    const channel = this.activeChannel();
    const selected = this.selected;
    if (channel === undefined || !this.ready(!candidate.isTest) || !this.current(candidate)) {
      return;
    }
    if (this.policy.remaining(this.clock.uptime()) > 0) {
      this.view.status = WearableStatus.COOLDOWN;
      this.view.detail = '腕上10秒独立冷却中；丢弃当次事件，不排队补发';
      this.publish();
      return;
    }
    this.pending = true;
    this.testPending = candidate.isTest;
    this.view.status = WearableStatus.CHECKING;
    const operation = new WearableOperation();
    const current = (): boolean => operation.active && this.current(candidate);
    this.publish();
    let attempted = false;
    try {
      channel.listen((): void => { this.serviceDied(); });
      if (candidate.route === WearableReminderRoute.NOTIFICATION_SYNC) {
        const notificationChannel = this.notificationChannel;
        if (notificationChannel === undefined) {
          return;
        }
        await this.bounded<void>(notificationChannel.check(current), operation,
          candidate.deadlineUptime - this.clock.uptime());
        if (!current()) {
          return;
        }
        this.notificationReady = true;
        this.notificationCheckNeeded = false;
      } else {
        const devices = await this.bounded<WearableDeviceChoice[]>(channel.discover(current), operation,
          candidate.deadlineUptime - this.clock.uptime());
        if (!current()) {
          return;
        }
        this.applyDevices(devices);
        const target = this.selected;
        if (selected === undefined || target === undefined || target.routeId !== selected.routeId || !target.supported) {
          throw new WearableChannelError(0, target !== undefined && !target.supported ?
            WearableStatus.UNSUPPORTED : WearableStatus.DISCONNECTED,
            '当前路由或通知能力已失效，请重新选择设备；本次提醒不补发');
        }
      }
      if (!current()) {
        return;
      }
      if (!this.policy.claim(this.clock.uptime()) || !current()) {
        return;
      }
      this.local.lastAttemptAt = this.clock.wall() + candidate.deadlineUptime - this.clock.uptime();
      this.local.lastAttemptUptime = candidate.deadlineUptime;
      const saved = await this.bounded<boolean>(this.persist(), operation,
        candidate.deadlineUptime - this.clock.uptime());
      if (!saved) {
        throw new WearableChannelError(0, WearableStatus.FAILED, '独立冷却保存失败，未向设备提交通知');
      }
      if (!current()) {
        return;
      }
      this.policy.markStarted(this.clock.uptime());
      this.local.lastAttemptAt = this.clock.wall();
      this.local.lastAttemptUptime = this.clock.uptime();
      if (candidate.isTest) {
        this.beginTest(candidate, true, '发送请求中；实际显示和振动待确认');
      }
      this.record(candidate, '请求已提交', 0, true);
      this.persist();
      this.sdkInFlight = true;
      this.view.status = WearableStatus.SENDING;
      this.publish();
      attempted = true;
      const sending = channel.send(selected?.routeId ?? '', candidate, current, (action: number, code: number): void => {
        this.feedback(candidate, action, code);
      });
      sending.then((): void => { this.sdkInFlight = false; this.publish(); },
        (): void => { this.sdkInFlight = false; this.publish(); });
      await this.bounded<void>(sending, operation, 5000);
      const success = candidate.route === WearableReminderRoute.NOTIFICATION_SYNC ?
        '手机通知发布请求成功；腕上送达未确认' : '发送请求成功；未确认腕上显示或振动';
      this.updateDiagnostic(candidate, success, 0);
      if (this.sameContext(candidate)) {
        this.view.status = WearableStatus.COOLDOWN;
        this.view.detail = success + '，不自动重发';
      }
      this.testResult(candidate, success);
    } catch (error) {
      const failure = error instanceof WearableChannelError ? error :
        new WearableChannelError(0, WearableStatus.FAILED, '穿戴调用失败，不自动重发');
      if (attempted) {
        this.updateDiagnostic(candidate, failure.message, failure.code);
        this.testResult(candidate, failure.message);
      } else if (candidate.isTest && this.sameContext(candidate)) {
        const detail = '未提交：' + failure.message;
        this.beginTest(candidate, false, detail);
        this.record(candidate, detail, failure.code, false);
        this.persist();
      }
      if (this.sameContext(candidate)) {
        this.fail(failure);
      }
    } finally {
      operation.active = false;
      if (candidate.isTest && candidate.generation === this.generation) {
        this.testPending = false;
      }
      if (candidate.generation === this.generation) {
        this.pending = false;
        this.publish();
      }
    }
  }

  private applyDevices(devices: WearableDeviceChoice[]): void {
    this.view.devices = devices;
    const previous = this.selected;
    this.selected = previous === undefined ? undefined :
      devices.find((device: WearableDeviceChoice): boolean => device.routeId === previous.routeId);
  }

  private serviceDied(): void {
    if (this.route !== WearableReminderRoute.WEAR_ENGINE) {
      return;
    }
    this.invalidate();
    this.selected = undefined;
    this.view.devices = [];
    this.view.status = this.enabled ? WearableStatus.DISCONNECTED : WearableStatus.OFF;
    this.view.detail = 'Wear Engine服务断开；不会补发旧通知，请刷新并重选目标';
    this.publish();
  }

  private fail(error: WearableChannelError): void {
    this.notificationReady = false;
    this.notificationCheckNeeded = false;
    this.view.status = error.status;
    this.view.detail = error.message + (error.code === 0 ? '' : '（' + error.code.toString() + '）');
    this.selected = undefined;
  }

  private bounded<T>(pending: Promise<T>, operation: WearableOperation, timeoutMs: number): Promise<T> {
    const wait = new WearableWait();
    return new Promise<T>((resolve, reject): void => {
      wait.cancel = (): void => {
        operation.active = false;
        reject(new WearableChannelError(0, WearableStatus.UNKNOWN,
          '本地待办已取消；若请求已交系统，结果未知且不自动重发'));
      };
      wait.id = setTimeout((): void => {
        this.waits.delete(wait);
        operation.active = false;
        reject(new WearableChannelError(0, WearableStatus.UNKNOWN, '请求超时，结果未知；不自动重发或切换通道'));
      }, Math.max(1, Math.min(60000, timeoutMs)));
      this.waits.add(wait);
      pending.then((value: T): void => {
        clearTimeout(wait.id);
        this.waits.delete(wait);
        resolve(value);
      }, (error: Error): void => {
        clearTimeout(wait.id);
        this.waits.delete(wait);
        reject(error);
      });
    });
  }

  private testResult(candidate: WearableCandidate, result: string): void {
    if (candidate.isTest && this.lastTestEvent === candidate.eventId) {
      this.local.testResult = result;
      this.persist();
    }
  }

  private beginTest(candidate: WearableCandidate, submitted: boolean, result: string): void {
    this.lastTestEvent = candidate.eventId;
    this.local.testEventId = candidate.eventId;
    this.local.testSubmitted = submitted;
    this.local.testAt = this.clock.wall();
    this.local.testRoute = candidate.route;
    this.local.testResult = result;
    this.local.testFeedback = '';
    this.local.confirmation = WearableTestConfirmation.UNCONFIRMED;
    this.local.model = this.selected?.model ?? '';
    this.local.softwareVersion = this.selected?.softwareVersion ?? '';
  }

  private feedback(candidate: WearableCandidate, action: number, code: number): void {
    this.prune();
    const diagnostic = this.diagnostics.find((item: WearableDiagnostic): boolean => item.eventId === candidate.eventId);
    if (diagnostic !== undefined) {
      diagnostic.action = action;
      diagnostic.feedbackErrorCode = code;
      diagnostic.feedback = code !== 0 ? '设备回调错误' : action === 0 ? '通知转入后台' :
        action === 1 ? '通知已被删除' : action === 2 ? '用户点击知道了' : '收到设备动作回调';
      if (candidate.isTest && this.lastTestEvent === candidate.eventId) {
        this.local.testFeedback = diagnostic.feedback + '；不代表振动或姿态恢复';
      }
      this.persist();
      this.publish();
    }
  }

  private record(candidate: WearableCandidate, result: string, code: number, submitted: boolean): void {
    let diagnostic = this.diagnostics.find((item: WearableDiagnostic): boolean => item.eventId === candidate.eventId);
    if (diagnostic === undefined) {
      diagnostic = new WearableDiagnostic();
      diagnostic.eventId = candidate.eventId;
      diagnostic.timestamp = this.clock.wall();
      diagnostic.isTest = candidate.isTest;
      diagnostic.route = candidate.route;
      this.diagnostics.unshift(diagnostic);
    }
    diagnostic.result = result;
    diagnostic.errorCode = code;
    diagnostic.submitted = submitted;
  }

  private updateDiagnostic(candidate: WearableCandidate, result: string, code: number): void {
    const diagnostic = this.diagnostics.find((item: WearableDiagnostic): boolean => item.eventId === candidate.eventId);
    if (diagnostic !== undefined) {
      diagnostic.result = result;
      if (code !== 0) {
        diagnostic.errorCode = code;
      }
      this.persist();
    }
  }

  private async persist(): Promise<boolean> {
    const snapshot = new WearableLocalState();
    snapshot.lastAttemptAt = this.local.lastAttemptAt;
    snapshot.lastAttemptUptime = this.local.lastAttemptUptime;
    snapshot.testAt = this.local.testAt;
    snapshot.testEventId = this.local.testEventId;
    snapshot.testSubmitted = this.local.testSubmitted;
    snapshot.testRoute = this.local.testRoute;
    snapshot.testResult = this.local.testResult;
    snapshot.testFeedback = this.local.testFeedback;
    snapshot.confirmation = this.local.confirmation;
    snapshot.model = this.local.model;
    snapshot.softwareVersion = this.local.softwareVersion;
    snapshot.diagnostics = this.diagnostics.filter((item: WearableDiagnostic): boolean =>
      item.timestamp <= this.clock.wall() && this.clock.wall() - item.timestamp <= WEARABLE_DIAGNOSTIC_TTL_MS)
      .slice(0, 100).map((item: WearableDiagnostic): WearableDiagnostic => copyWearableDiagnostic(item));
    const generation = this.generation;
    let saved = false;
    try {
      saved = await this.save(snapshot);
    } catch (error) {
      saved = false;
    }
    if (generation === this.generation) {
      this.view.storageHealthy = saved;
      this.publish();
    }
    return saved;
  }

  private prune(): void {
    const now = this.clock.wall();
    this.diagnostics = this.diagnostics.filter((item: WearableDiagnostic): boolean =>
      item.timestamp <= now && now - item.timestamp <= WEARABLE_DIAGNOSTIC_TTL_MS).slice(0, 100);
    if (this.local.testAt > 0 && (this.local.testAt > now || now - this.local.testAt > WEARABLE_DIAGNOSTIC_TTL_MS)) {
      this.local.testAt = 0;
      this.local.testEventId = '';
      this.local.testSubmitted = false;
      this.local.testResult = '';
      this.local.testFeedback = '';
      this.local.confirmation = WearableTestConfirmation.UNCONFIRMED;
      this.local.model = '';
      this.local.softwareVersion = '';
      this.lastTestEvent = '';
      this.persist();
    }
  }

  private publish(): void {
    const state = this.state();
    if (this.view.status === WearableStatus.COOLDOWN && state.cooldownRemainingMs === 0 && !state.busy) {
      this.view.status = this.idleStatus();
      state.status = this.view.status;
    }
    this.listener(state);
    if (this.enabled && this.loaded && this.runtime.foreground && state.cooldownRemainingMs > 0 &&
      this.cooldownTimer < 0) {
      this.cooldownTimer = setTimeout((): void => {
        this.cooldownTimer = -1;
        this.publish();
      }, state.cooldownRemainingMs + 1);
    }
  }
}

export class WearableReminderService {
  static readonly controller: WearableReminderController =
    new WearableReminderController(new DeviceWearableClock(), WEARABLE_REMINDER_POLICY);
  private static lifecycle: number = 0;
  private static pageSequence: number = 0;
  private static pageOwner: number = 0;
  private static cleanup: Promise<void> = Promise.resolve();

  static beginPage(): number {
    WearableReminderService.destroy();
    WearableReminderService.pageSequence += 1;
    WearableReminderService.pageOwner = WearableReminderService.pageSequence;
    return WearableReminderService.pageOwner;
  }

  static isCurrentPage(pageId: number): boolean {
    return pageId > 0 && pageId === WearableReminderService.pageOwner;
  }

  static async initialize(context: common.UIAbilityContext, pageId: number): Promise<void> {
    if (!WearableReminderService.isCurrentPage(pageId)) {
      return;
    }
    const lifecycle = ++WearableReminderService.lifecycle;
    await WearableReminderService.cleanup;
    if (lifecycle !== WearableReminderService.lifecycle) {
      return;
    }
    const local = await PostureSessionStore.loadWearable(context);
    if (lifecycle !== WearableReminderService.lifecycle) {
      return;
    }
    WearableReminderService.controller.attach(new WearEngineNotificationChannel(context),
      (state: WearableLocalState): Promise<boolean> => PostureSessionStore.saveWearable(context, state), local,
      new PhoneNotificationReminderChannel(context));
  }

  static async destroy(pageId: number = 0): Promise<void> {
    if (pageId > 0 && !WearableReminderService.isCurrentPage(pageId)) {
      return;
    }
    WearableReminderService.pageOwner = 0;
    WearableReminderService.lifecycle += 1;
    const closing = WearableReminderService.controller.close();
    WearableReminderService.cleanup = WearableReminderService.cleanup.then(async (): Promise<void> => {
      await closing;
    });
    await WearableReminderService.cleanup;
  }
}
