import { MetricResult, Point2D, PostureAlertType, PostureLevel, PostureResult, PostureSample } from './PostureTypes';

export enum LowScoreLevel {
  NORMAL = 0,
  LIGHT = 1,
  MEDIUM = 2,
  SEVERE = 3
}

export const LOW_SCORE_CONFIRM_MS = 6000;
export const PHONE_VIBRATION_COOLDOWN_MS = 60000;
const BREAK_INTERVAL_MS = 20 * 60 * 1000;
const MIN_POINT_SCORE = 0.35;
const MIN_FACE_CONFIDENCE = 0.25;

export class ReminderVibrationCooldown {
  private lastFeedbackAt: number = -1;

  claim(now: number): boolean {
    if (!Number.isFinite(now) || now < 0 ||
      this.lastFeedbackAt >= 0 && now - this.lastFeedbackAt < PHONE_VIBRATION_COOLDOWN_MS) {
      return false;
    }
    this.lastFeedbackAt = now;
    return true;
  }

  markStarted(now: number): void {
    if (Number.isFinite(now) && now >= 0) {
      this.lastFeedbackAt = Math.max(this.lastFeedbackAt, now);
    }
  }
}

export const PHONE_VIBRATION_COOLDOWN: ReminderVibrationCooldown = new ReminderVibrationCooldown();

export class LowScoreReminderContext {
  sessionId: number = 0;
  startedAt: number = 0;
  intervalMs: number = 3000;
  foreground: boolean = false;
  guarding: boolean = false;
  calibrating: boolean = false;
  realSource: boolean = false;
  edgeLightEnabled: boolean = true;
  reduceMotion: boolean = false;
  vibrationEnabled: boolean = true;
  vibrationAvailable: boolean = true;
}

export class LowScoreDecision {
  level: LowScoreLevel = LowScoreLevel.NORMAL;
  message: string = '';
  alertType: PostureAlertType = PostureAlertType.NONE;
  edgeVisible: boolean = false;
  reduceMotion: boolean = false;
  visualEvent: boolean = false;
  vibrate: boolean = false;
  breakEvent: boolean = false;
  validSample: boolean = false;
  expiresAt: number = 0;
}

class ThresholdConfirmation {
  private threshold: number;
  private firstAt: number = -1;
  private count: number = 0;

  constructor(threshold: number) {
    this.threshold = threshold;
  }

  feed(score: number, timestamp: number): boolean {
    if (score >= this.threshold) {
      this.clear();
      return false;
    }
    if (this.count === 0) {
      this.firstAt = timestamp;
    }
    this.count += 1;
    return this.count >= 2 && timestamp - this.firstAt >= LOW_SCORE_CONFIRM_MS;
  }

  clear(): void {
    this.firstAt = -1;
    this.count = 0;
  }
}

function reliablePoint(point: Point2D | undefined): boolean {
  return point !== undefined && Number.isFinite(point.x) && Number.isFinite(point.y) &&
    Number.isFinite(point.score) && point.score >= MIN_POINT_SCORE && point.score <= 1;
}

export function reminderSampleIsReliable(sample: PostureSample, result: PostureResult): boolean {
  const face = sample.face;
  const rect = face.rect;
  const evidence = sample.reminderEvidence;
  if (!Number.isFinite(result.score) || result.score < 0 || result.score > 100 ||
    result.timestamp !== sample.timestamp || !Number.isFinite(face.confidence) ||
    face.confidence < MIN_FACE_CONFIDENCE || face.confidence > 1 ||
    !Number.isFinite(face.pitch) || !Number.isFinite(face.roll) || !Number.isFinite(face.yaw) ||
    rect === undefined || !Number.isFinite(rect.left) || !Number.isFinite(rect.top) ||
    !Number.isFinite(rect.width) || !Number.isFinite(rect.height) || rect.width <= 1 || rect.height <= 1 ||
    evidence === undefined || evidence.faceCount !== 1 || evidence.skeletonCount !== 1 ||
    evidence.associationAmbiguous || result.sit.level === PostureLevel.UNKNOWN ||
    result.chin.level === PostureLevel.UNKNOWN) {
    return false;
  }
  return reliablePoint(sample.skeleton.nose) && reliablePoint(sample.skeleton.leftShoulder) &&
    reliablePoint(sample.skeleton.rightShoulder);
}

function reliableProblem(result: PostureResult): PostureAlertType {
  const type = result.primaryAlert;
  if (type === PostureAlertType.NONE || type === PostureAlertType.ITEM_12 ||
    !result.activeAlerts.includes(type)) {
    return PostureAlertType.NONE;
  }
  const metrics: MetricResult[] = [result.sit, result.chin, result.mouth];
  const match = metrics.find((metric: MetricResult): boolean => metric.alertType === type &&
    (metric.level === PostureLevel.WARN || metric.level === PostureLevel.BAD));
  return match !== undefined ? type : PostureAlertType.NONE;
}

export function lowScoreAdvice(type: PostureAlertType): string {
  if (type === PostureAlertType.ITEM_01 || type === PostureAlertType.KYPHOSIS) {
    return '请轻轻挺直背部';
  }
  if (type === PostureAlertType.ITEM_02 || type === PostureAlertType.SHOULDER_TILT) {
    return '请坐正，放平双肩';
  }
  if (type === PostureAlertType.ITEM_03 || type === PostureAlertType.HEAD_DROP) {
    return '请抬头';
  }
  if (type === PostureAlertType.ITEM_05) {
    return '请轻收下巴';
  }
  if (type === PostureAlertType.ITEM_06) {
    return '请保持头部居中';
  }
  if (type === PostureAlertType.ITEM_07 || type === PostureAlertType.BODY_SLIDE) {
    return '请轻靠回椅背';
  }
  if (type === PostureAlertType.ITEM_10) {
    return '请适当抬高屏幕';
  }
  if (type === PostureAlertType.ITEM_11 || type === PostureAlertType.MOUTH_OPEN) {
    return '请轻合嘴唇';
  }
  return '请调整坐姿';
}

export function reminderExpiryMs(intervalMs: number): number {
  const interval = Number.isFinite(intervalMs) && intervalMs > 0 ? intervalMs : 3000;
  return Math.max(interval * 2 + 1000, LOW_SCORE_CONFIRM_MS);
}

export class LowScoreReminderScheduler {
  private light: ThresholdConfirmation = new ThresholdConfirmation(70);
  private medium: ThresholdConfirmation = new ThresholdConfirmation(60);
  private severe: ThresholdConfirmation = new ThresholdConfirmation(50);
  private level: LowScoreLevel = LowScoreLevel.NORMAL;
  private recoverLight: number = 0;
  private recoverMedium: number = 0;
  private recoverSevere: number = 0;
  private sessionId: number = 0;
  private lastTimestamp: number = -1;
  private lastValidAt: number = -1;
  private lastBreakAt: number = -1;
  private problem: PostureAlertType = PostureAlertType.NONE;
  private cooldown: ReminderVibrationCooldown;

  constructor(cooldown: ReminderVibrationCooldown = PHONE_VIBRATION_COOLDOWN) {
    this.cooldown = cooldown;
  }

  beginSession(sessionId: number, startedAt: number): void {
    this.clearContinuity();
    this.sessionId = sessionId;
    this.lastTimestamp = -1;
    this.lastBreakAt = startedAt;
  }

  stop(): void {
    this.clearContinuity();
    this.sessionId = 0;
    this.lastTimestamp = -1;
    this.lastBreakAt = -1;
  }

  invalidate(): LowScoreDecision {
    this.clearContinuity();
    return new LowScoreDecision();
  }

  refresh(context: LowScoreReminderContext, now: number): LowScoreDecision {
    if (!this.active(context) || !Number.isFinite(now) ||
      this.lastValidAt >= 0 && (now < this.lastValidAt || now - this.lastValidAt > reminderExpiryMs(context.intervalMs))) {
      return this.invalidate();
    }
    return this.snapshot(context);
  }

  feed(sample: PostureSample, result: PostureResult, context: LowScoreReminderContext, now: number): LowScoreDecision {
    if (context.sessionId !== this.sessionId) {
      return this.snapshot(context);
    }
    this.refresh(context, now);
    if (!this.active(context)) {
      return this.invalidate();
    }
    const timestamp = sample.timestamp;
    if (!Number.isFinite(timestamp) || !Number.isFinite(now) || timestamp < context.startedAt ||
      timestamp > now || now - timestamp > reminderExpiryMs(context.intervalMs)) {
      return this.invalidate();
    }
    if (!reminderSampleIsReliable(sample, result)) {
      this.lastTimestamp = Math.max(this.lastTimestamp, timestamp);
      return this.invalidate();
    }
    if (timestamp <= this.lastTimestamp) {
      return this.snapshot(context);
    }
    this.lastTimestamp = timestamp;
    if (this.lastValidAt >= 0 && timestamp - this.lastValidAt > reminderExpiryMs(context.intervalMs)) {
      this.clearContinuity();
    }
    this.lastValidAt = timestamp;
    this.problem = reliableProblem(result);
    const previous = this.level;
    const lightConfirmed = this.light.feed(result.score, timestamp);
    const mediumConfirmed = this.medium.feed(result.score, timestamp);
    const severeConfirmed = this.severe.feed(result.score, timestamp);
    this.recoverLight = result.score >= 73 ? this.recoverLight + 1 : 0;
    this.recoverMedium = result.score >= 63 ? this.recoverMedium + 1 : 0;
    this.recoverSevere = result.score >= 53 ? this.recoverSevere + 1 : 0;
    if (this.level >= LowScoreLevel.LIGHT && this.recoverLight >= 2) {
      this.level = LowScoreLevel.NORMAL;
    } else if (this.level >= LowScoreLevel.MEDIUM && this.recoverMedium >= 2) {
      this.level = LowScoreLevel.LIGHT;
    } else if (this.level === LowScoreLevel.SEVERE && this.recoverSevere >= 2) {
      this.level = LowScoreLevel.MEDIUM;
    }
    if (severeConfirmed) {
      this.level = LowScoreLevel.SEVERE;
    } else if (mediumConfirmed && this.level < LowScoreLevel.MEDIUM) {
      this.level = LowScoreLevel.MEDIUM;
    } else if (lightConfirmed && this.level < LowScoreLevel.LIGHT) {
      this.level = LowScoreLevel.LIGHT;
    }
    const decision = this.snapshot(context);
    decision.validSample = true;
    decision.visualEvent = this.level > previous && previous < LowScoreLevel.MEDIUM &&
      (decision.edgeVisible || this.level >= LowScoreLevel.MEDIUM);
    if (this.level === LowScoreLevel.SEVERE && result.score < 50 && context.vibrationEnabled &&
      context.vibrationAvailable) {
      decision.vibrate = this.cooldown.claim(now);
    }
    if (this.level === LowScoreLevel.NORMAL && timestamp - this.lastBreakAt >= BREAK_INTERVAL_MS) {
      decision.breakEvent = true;
      decision.message = '坐久了，放松身体，休息一下';
      decision.alertType = PostureAlertType.ITEM_12;
      this.lastBreakAt = timestamp;
    }
    return decision;
  }

  private active(context: LowScoreReminderContext): boolean {
    return this.sessionId > 0 && context.sessionId === this.sessionId && context.foreground &&
      context.guarding && !context.calibrating && context.realSource;
  }

  private snapshot(context: LowScoreReminderContext): LowScoreDecision {
    const decision = new LowScoreDecision();
    if (!this.active(context) || this.lastValidAt < 0) {
      return decision;
    }
    decision.level = this.level;
    decision.message = this.level >= LowScoreLevel.MEDIUM ? lowScoreAdvice(this.problem) : '';
    decision.alertType = this.level > LowScoreLevel.NORMAL ? this.problem : PostureAlertType.NONE;
    decision.edgeVisible = this.level > LowScoreLevel.NORMAL && context.edgeLightEnabled;
    decision.reduceMotion = context.reduceMotion;
    decision.expiresAt = this.lastValidAt + reminderExpiryMs(context.intervalMs);
    return decision;
  }

  private clearContinuity(): void {
    this.light.clear();
    this.medium.clear();
    this.severe.clear();
    this.level = LowScoreLevel.NORMAL;
    this.recoverLight = 0;
    this.recoverMedium = 0;
    this.recoverSevere = 0;
    this.lastValidAt = -1;
    this.problem = PostureAlertType.NONE;
  }
}
