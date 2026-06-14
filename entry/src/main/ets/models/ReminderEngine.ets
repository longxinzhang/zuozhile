import { PostureAlertType, PostureResult, ReminderAction } from './PostureTypes';

const ALERT_COOLDOWN_MS = 120000;

interface AlertState {
  type: PostureAlertType;
  firstTriggeredAt: number;
  consecutiveCount: number;
  lastAlertAt: number;
}

interface AlertRule {
  type: PostureAlertType;
  durationMs: number;
  hardDurationMs: number;
}

const ALERT_RULES: AlertRule[] = [
  { type: PostureAlertType.BODY_SLIDE, durationMs: 30000, hardDurationMs: 45000 },
  { type: PostureAlertType.HEAD_DROP, durationMs: 20000, hardDurationMs: 35000 },
  { type: PostureAlertType.KYPHOSIS, durationMs: 25000, hardDurationMs: 40000 },
  { type: PostureAlertType.SHOULDER_TILT, durationMs: 20000, hardDurationMs: 35000 },
  { type: PostureAlertType.MOUTH_OPEN, durationMs: 15000, hardDurationMs: 30000 }
];

const ALERT_PRIORITY: PostureAlertType[] = [
  PostureAlertType.BODY_SLIDE,
  PostureAlertType.HEAD_DROP,
  PostureAlertType.KYPHOSIS,
  PostureAlertType.SHOULDER_TILT,
  PostureAlertType.MOUTH_OPEN
];

function createState(type: PostureAlertType): AlertState {
  return {
    type,
    firstTriggeredAt: 0,
    consecutiveCount: 0,
    lastAlertAt: 0
  };
}

function ruleFor(type: PostureAlertType): AlertRule {
  const match = ALERT_RULES.find((rule: AlertRule) => rule.type === type);
  if (match) {
    return match;
  }
  return { type, durationMs: 20000, hardDurationMs: 35000 };
}

function priorityRank(type: PostureAlertType): number {
  const index = ALERT_PRIORITY.indexOf(type);
  return index >= 0 ? index : ALERT_PRIORITY.length;
}

export class ReminderEngine {
  private states: AlertState[] = ALERT_RULES.map((rule: AlertRule) => createState(rule.type));
  private lastAlertType: PostureAlertType = PostureAlertType.NONE;

  reset(): void {
    this.states = ALERT_RULES.map((rule: AlertRule) => createState(rule.type));
    this.lastAlertType = PostureAlertType.NONE;
  }

  feed(result: PostureResult, now: number): ReminderAction {
    let selectedType = PostureAlertType.NONE;
    let selectedAction = ReminderAction.NONE;

    this.states.forEach((state: AlertState) => {
      const isTriggered = result.activeAlerts.includes(state.type);
      const action = this.feedState(state, isTriggered, now);
      if (action === ReminderAction.NONE) {
        return;
      }
      if (selectedAction === ReminderAction.NONE ||
        action === ReminderAction.HARD && selectedAction !== ReminderAction.HARD ||
        action === selectedAction && priorityRank(state.type) < priorityRank(selectedType)) {
        selectedAction = action;
        selectedType = state.type;
      }
    });

    this.lastAlertType = selectedAction === ReminderAction.NONE ? PostureAlertType.NONE : selectedType;
    return selectedAction;
  }

  alertDetail(): string {
    if (this.lastAlertType === PostureAlertType.NONE) {
      return '';
    }
    return alertTypeLabel(this.lastAlertType);
  }

  alertType(): PostureAlertType {
    return this.lastAlertType;
  }

  private feedState(state: AlertState, isTriggered: boolean, now: number): ReminderAction {
    if (!isTriggered) {
      state.firstTriggeredAt = 0;
      state.consecutiveCount = 0;
      return ReminderAction.NONE;
    }

    if (state.consecutiveCount === 0) {
      state.firstTriggeredAt = now;
    }
    state.consecutiveCount += 1;

    const rule = ruleFor(state.type);
    const held = now - state.firstTriggeredAt;
    const cooled = now - state.lastAlertAt >= ALERT_COOLDOWN_MS;
    if (!cooled) {
      return ReminderAction.NONE;
    }

    if (held >= rule.hardDurationMs) {
      state.lastAlertAt = now;
      return ReminderAction.HARD;
    }
    if (held >= rule.durationMs) {
      state.lastAlertAt = now;
      return ReminderAction.SOFT;
    }
    return ReminderAction.NONE;
  }
}

export function alertTypeLabel(type: PostureAlertType): string {
  if (type === PostureAlertType.BODY_SLIDE) {
    return '身体下滑';
  }
  if (type === PostureAlertType.HEAD_DROP) {
    return '低头';
  }
  if (type === PostureAlertType.KYPHOSIS) {
    return '含胸';
  }
  if (type === PostureAlertType.SHOULDER_TILT) {
    return '歪斜';
  }
  if (type === PostureAlertType.MOUTH_OPEN) {
    return '张嘴';
  }
  return '';
}

export function actionLabel(action: ReminderAction, type: PostureAlertType = PostureAlertType.NONE): string {
  const detail = alertTypeLabel(type);
  if (action === ReminderAction.HARD) {
    return detail.length > 0 ? '强提醒 · ' + detail : '强提醒';
  }
  if (action === ReminderAction.SOFT) {
    return detail.length > 0 ? '轻提醒 · ' + detail : '轻提醒';
  }
  return '无提醒';
}
