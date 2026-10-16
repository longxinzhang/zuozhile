import { LowScoreDecision, LowScoreLevel } from './LowScoreReminder';
import { PostureAlertType, WearableReminderRoute } from './PostureTypes';

export const WEARABLE_COOLDOWN_MS = 10000;
export const WEARABLE_EVENT_TTL_MS = 5000;
export const WEARABLE_DIAGNOSTIC_TTL_MS = 86400000;

export enum WearableStatus {
  OFF = '未开启',
  CONFIGURATION = '待配置',
  DISCONNECTED = '未连接',
  UNSUPPORTED = '设备不支持',
  SELECT = '请选择设备',
  CHECKING = '检查中',
  READY = '就绪',
  COOLDOWN = '冷却中',
  SENDING = '发送中',
  FAILED = '发送失败',
  UNKNOWN = '结果未知'
}

export enum WearableTestConfirmation {
  UNCONFIRMED = '尚未确认',
  VIBRATED = '收到并振动',
  DISPLAYED = '只收到通知',
  NOT_RECEIVED = '没收到'
}

export class WearableDeviceChoice {
  routeId: string = '';
  name: string = '';
  model: string = '';
  softwareVersion: string = '';
  supported: boolean = false;
}

export class WearableDiagnostic {
  eventId: string = '';
  timestamp: number = 0;
  isTest: boolean = false;
  route: WearableReminderRoute = WearableReminderRoute.WEAR_ENGINE;
  result: string = '';
  errorCode: number = 0;
  action: number = -1;
  feedback: string = '';
  feedbackErrorCode: number = 0;
  submitted: boolean = false;
  confirmation: WearableTestConfirmation = WearableTestConfirmation.UNCONFIRMED;
}

export class WearableLocalState {
  lastAttemptAt: number = 0;
  lastAttemptUptime: number = 0;
  testAt: number = 0;
  testEventId: string = '';
  testSubmitted: boolean = false;
  testRoute: WearableReminderRoute = WearableReminderRoute.WEAR_ENGINE;
  testResult: string = '';
  testFeedback: string = '';
  confirmation: WearableTestConfirmation = WearableTestConfirmation.UNCONFIRMED;
  model: string = '';
  softwareVersion: string = '';
  diagnostics: WearableDiagnostic[] = [];
}

export class WearableViewState {
  route: WearableReminderRoute = WearableReminderRoute.NOTIFICATION_SYNC;
  status: WearableStatus = WearableStatus.OFF;
  detail: string = '腕上提醒默认关闭，手机提醒保持原样';
  devices: WearableDeviceChoice[] = [];
  selectedId: string = '';
  selectedName: string = '';
  busy: boolean = false;
  canTest: boolean = false;
  canConfirmTest: boolean = false;
  cooldownRemainingMs: number = 0;
  storageHealthy: boolean = true;
  testAt: number = 0;
  testRoute: WearableReminderRoute = WearableReminderRoute.WEAR_ENGINE;
  testResult: string = '';
  testFeedback: string = '';
  testModel: string = '';
  testSoftwareVersion: string = '';
  confirmation: WearableTestConfirmation = WearableTestConfirmation.UNCONFIRMED;
  diagnosticCount: number = 0;
  diagnostics: WearableDiagnostic[] = [];
}

export class WearableRuntime {
  foreground: boolean = false;
  guarding: boolean = false;
  calibrating: boolean = false;
  realSource: boolean = false;
  testAllowed: boolean = false;
  sessionId: number = 0;
  pageId: number = 0;
  score: number = 100;
  expiresAt: number = 0;
  level: LowScoreLevel = LowScoreLevel.NORMAL;
}

export class WearableCandidate {
  route: WearableReminderRoute = WearableReminderRoute.WEAR_ENGINE;
  eventId: string = '';
  sessionId: number = 0;
  pageId: number = 0;
  generation: number = 0;
  sampleTimestamp: number = 0;
  level: LowScoreLevel = LowScoreLevel.NORMAL;
  score: number = 100;
  adviceCode: PostureAlertType = PostureAlertType.NONE;
  expiresAt: number = 0;
  createdUptime: number = 0;
  deadlineUptime: number = 0;
  isTest: boolean = false;
}

export class WearableReminderPolicy {
  private deadline: number = 0;
  private lastUptime: number = 0;
  private sequence: number = 0;
  private lastSession: number = -1;
  private lastPage: number = -1;
  private lastSample: number = -1;
  private restored: boolean = false;
  private restoredWallAt: number = 0;
  private restoredUptimeAt: number = 0;

  restore(wallAt: number, uptimeAt: number, wall: number, uptime: number): void {
    if (!Number.isFinite(uptime) || uptime < 0) {
      return;
    }
    const sameWall = wallAt === this.restoredWallAt ||
      !Number.isFinite(wallAt) && !Number.isFinite(this.restoredWallAt);
    const sameUptime = uptimeAt === this.restoredUptimeAt ||
      !Number.isFinite(uptimeAt) && !Number.isFinite(this.restoredUptimeAt);
    if (this.restored && sameWall && sameUptime && uptime >= this.lastUptime) {
      this.remaining(uptime);
      return;
    }
    this.restored = true;
    this.restoredWallAt = wallAt;
    this.restoredUptimeAt = uptimeAt;
    let remaining = 0;
    if (wallAt !== 0 || uptimeAt !== 0) {
      const wallElapsed = wall - wallAt;
      const uptimeElapsed = uptime - uptimeAt;
      remaining = !Number.isFinite(wallAt) || !Number.isFinite(uptimeAt) || !Number.isFinite(wall) ||
        wallAt < 0 || uptimeAt < 0 || wallElapsed < 0 || uptimeElapsed < 0 ? WEARABLE_COOLDOWN_MS :
        Math.max(0, WEARABLE_COOLDOWN_MS - Math.min(wallElapsed, uptimeElapsed));
    }
    if (uptime < this.lastUptime) {
      this.deadline = uptime + WEARABLE_COOLDOWN_MS;
    }
    this.deadline = Math.max(this.deadline, uptime + Math.min(WEARABLE_COOLDOWN_MS, remaining));
    this.lastUptime = uptime;
  }

  remaining(uptime: number): number {
    if (!Number.isFinite(uptime) || uptime < 0) {
      return WEARABLE_COOLDOWN_MS;
    }
    if (uptime < this.lastUptime) {
      this.deadline = uptime + WEARABLE_COOLDOWN_MS;
    }
    this.lastUptime = uptime;
    return Math.max(0, Math.min(WEARABLE_COOLDOWN_MS, this.deadline - uptime));
  }

  claim(uptime: number): boolean {
    if (this.remaining(uptime) > 0) {
      return false;
    }
    this.deadline = uptime + WEARABLE_COOLDOWN_MS;
    return true;
  }

  markStarted(uptime: number): void {
    if (Number.isFinite(uptime) && uptime >= 0) {
      this.remaining(uptime);
      this.deadline = Math.max(this.deadline, uptime + WEARABLE_COOLDOWN_MS);
    }
  }

  create(decision: LowScoreDecision, score: number, timestamp: number, runtime: WearableRuntime,
    generation: number, wall: number, uptime: number): WearableCandidate | undefined {
    if (!decision.validSample || decision.level !== LowScoreLevel.SEVERE || !Number.isFinite(score) ||
      score < 0 || score >= 50 || !Number.isFinite(timestamp) || timestamp < 0 || timestamp > wall ||
      !Number.isFinite(wall) || !Number.isFinite(uptime) || uptime < 0 ||
      !Number.isFinite(decision.expiresAt) || decision.expiresAt <= wall || runtime.score !== score ||
      runtime.level !== LowScoreLevel.SEVERE || runtime.expiresAt <= wall || !runtime.foreground ||
      !runtime.guarding || runtime.calibrating || !runtime.realSource || runtime.sessionId <= 0 || runtime.pageId <= 0) {
      return undefined;
    }
    if (this.lastSession === runtime.sessionId && this.lastPage === runtime.pageId && timestamp <= this.lastSample) {
      return undefined;
    }
    this.lastSession = runtime.sessionId;
    this.lastPage = runtime.pageId;
    this.lastSample = timestamp;
    const candidate = this.next(runtime, generation, wall, uptime, false);
    candidate.sampleTimestamp = timestamp;
    candidate.level = decision.level;
    candidate.score = score;
    candidate.adviceCode = decision.alertType;
    candidate.expiresAt = Math.min(decision.expiresAt, wall + WEARABLE_EVENT_TTL_MS);
    candidate.deadlineUptime = uptime + Math.min(WEARABLE_EVENT_TTL_MS, decision.expiresAt - wall);
    return candidate;
  }

  test(runtime: WearableRuntime, generation: number, wall: number, uptime: number): WearableCandidate {
    return this.next(runtime, generation, wall, uptime, true);
  }

  private next(runtime: WearableRuntime, generation: number, wall: number, uptime: number,
    isTest: boolean): WearableCandidate {
    this.sequence += 1;
    const candidate = new WearableCandidate();
    candidate.eventId = wall.toString() + ':' + uptime.toString() + ':' + runtime.pageId.toString() + ':' +
      runtime.sessionId.toString() + ':' + this.sequence.toString();
    candidate.sessionId = runtime.sessionId;
    candidate.pageId = runtime.pageId;
    candidate.generation = generation;
    candidate.expiresAt = wall + WEARABLE_EVENT_TTL_MS;
    candidate.createdUptime = uptime;
    candidate.deadlineUptime = uptime + WEARABLE_EVENT_TTL_MS;
    candidate.isTest = isTest;
    return candidate;
  }
}

export const WEARABLE_REMINDER_POLICY: WearableReminderPolicy = new WearableReminderPolicy();

export function copyWearableDiagnostic(source: WearableDiagnostic): WearableDiagnostic {
  const result = new WearableDiagnostic();
  result.eventId = source.eventId;
  result.timestamp = source.timestamp;
  result.isTest = source.isTest;
  result.route = source.route;
  result.result = source.result;
  result.errorCode = source.errorCode;
  result.action = source.action;
  result.feedback = source.feedback;
  result.feedbackErrorCode = source.feedbackErrorCode;
  result.submitted = source.submitted;
  result.confirmation = source.confirmation;
  return result;
}

export function wearableUtf8(value: string, maxBytes: number): string {
  let result = '';
  let bytes = 0;
  for (const char of value) {
    const point = char.codePointAt(0) ?? 0;
    const size = point <= 0x7f ? 1 : point <= 0x7ff ? 2 : point <= 0xffff ? 3 : 4;
    if (bytes + size > maxBytes) {
      break;
    }
    bytes += size;
    result += char;
  }
  return result;
}
