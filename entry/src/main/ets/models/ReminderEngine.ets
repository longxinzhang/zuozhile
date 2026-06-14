import { PostureAlertType, PostureResult, ReminderAction } from './PostureTypes';

const BREAK_INTERVAL_MS = 20 * 60 * 1000;

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
  cooldownMs: number;
}

const ALERT_RULES: AlertRule[] = [
  { type: PostureAlertType.ITEM_01, durationMs: 25000, hardDurationMs: 40000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_02, durationMs: 20000, hardDurationMs: 35000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_03, durationMs: 20000, hardDurationMs: 35000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_05, durationMs: 20000, hardDurationMs: 35000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_06, durationMs: 20000, hardDurationMs: 35000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_07, durationMs: 25000, hardDurationMs: 40000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_10, durationMs: 15000, hardDurationMs: 30000, cooldownMs: 300000 },
  { type: PostureAlertType.ITEM_11, durationMs: 15000, hardDurationMs: 30000, cooldownMs: 120000 },
  { type: PostureAlertType.ITEM_12, durationMs: 0, hardDurationMs: -1, cooldownMs: 0 }
];

const ALERT_PRIORITY: PostureAlertType[] = [
  PostureAlertType.ITEM_02,
  PostureAlertType.ITEM_01,
  PostureAlertType.ITEM_07,
  PostureAlertType.ITEM_03,
  PostureAlertType.ITEM_05,
  PostureAlertType.ITEM_10,
  PostureAlertType.ITEM_06,
  PostureAlertType.ITEM_11,
  PostureAlertType.ITEM_12
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
  return { type, durationMs: 20000, hardDurationMs: 35000, cooldownMs: 120000 };
}

function priorityRank(type: PostureAlertType): number {
  const index = ALERT_PRIORITY.indexOf(type);
  return index >= 0 ? index : ALERT_PRIORITY.length;
}

export class ReminderEngine {
  private states: AlertState[] = ALERT_RULES.map((rule: AlertRule) => createState(rule.type));
  private lastAlertType: PostureAlertType = PostureAlertType.NONE;
  private item03AlertCount: number = 0;
  private lastBreakReminderAt: number = Date.now();

  reset(): void {
    this.states = ALERT_RULES.map((rule: AlertRule) => createState(rule.type));
    this.lastAlertType = PostureAlertType.NONE;
    this.item03AlertCount = 0;
    this.lastBreakReminderAt = Date.now();
  }

  feed(result: PostureResult, now: number): ReminderAction {
    let selectedType: PostureAlertType = PostureAlertType.NONE;
    let selectedAction: ReminderAction = ReminderAction.NONE;
    const activeAlerts = result.activeAlerts.slice();
    if (this.item03AlertCount >= 3 && activeAlerts.includes(PostureAlertType.ITEM_03)) {
      activeAlerts.push(PostureAlertType.ITEM_10);
    }
    if (now - this.lastBreakReminderAt >= BREAK_INTERVAL_MS) {
      activeAlerts.push(PostureAlertType.ITEM_12);
    }

    for (let index = 0; index < this.states.length; index += 1) {
      const state = this.states[index];
      const isTriggered = activeAlerts.includes(state.type);
      const action = this.feedState(state, isTriggered, now);
      if (action === ReminderAction.NONE) {
        continue;
      }
      if (selectedAction === ReminderAction.NONE ||
        action === ReminderAction.HARD && selectedAction !== ReminderAction.HARD ||
        action === selectedAction && priorityRank(state.type) < priorityRank(selectedType)) {
        selectedAction = action;
        selectedType = state.type;
      }
    }

    this.lastAlertType = selectedAction === ReminderAction.NONE ? PostureAlertType.NONE : selectedType;
    if (selectedAction !== ReminderAction.NONE && selectedType === PostureAlertType.ITEM_03) {
      this.item03AlertCount += 1;
    }
    if (selectedAction !== ReminderAction.NONE && selectedType === PostureAlertType.ITEM_10) {
      this.item03AlertCount = 0;
    }
    if (selectedAction !== ReminderAction.NONE && selectedType === PostureAlertType.ITEM_12) {
      this.lastBreakReminderAt = now;
    }
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
    const cooled = rule.cooldownMs <= 0 || now - state.lastAlertAt >= rule.cooldownMs;
    if (!cooled) {
      return ReminderAction.NONE;
    }

    if (rule.hardDurationMs >= 0 && held >= rule.hardDurationMs) {
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
  if (type === PostureAlertType.ITEM_01 || type === PostureAlertType.KYPHOSIS) {
    return '挺起来';
  }
  if (type === PostureAlertType.ITEM_02 || type === PostureAlertType.SHOULDER_TILT) {
    return '坐正';
  }
  if (type === PostureAlertType.ITEM_03 || type === PostureAlertType.HEAD_DROP) {
    return '抬头';
  }
  if (type === PostureAlertType.ITEM_05) {
    return '下巴收';
  }
  if (type === PostureAlertType.ITEM_06) {
    return '头别歪';
  }
  if (type === PostureAlertType.ITEM_07 || type === PostureAlertType.BODY_SLIDE) {
    return '靠回椅背';
  }
  if (type === PostureAlertType.ITEM_10) {
    return '屏幕抬高';
  }
  if (type === PostureAlertType.ITEM_11 || type === PostureAlertType.MOUTH_OPEN) {
    return '嘴巴轻合';
  }
  if (type === PostureAlertType.ITEM_12) {
    return '呼吸一下';
  }
  return '';
}

export function alertTypeTitle(type: PostureAlertType): string {
  if (type === PostureAlertType.ITEM_01 || type === PostureAlertType.KYPHOSIS) {
    return '挺起来一点～';
  }
  if (type === PostureAlertType.ITEM_02 || type === PostureAlertType.SHOULDER_TILT) {
    return '坐正一点～';
  }
  if (type === PostureAlertType.ITEM_03 || type === PostureAlertType.HEAD_DROP) {
    return '抬头一点～';
  }
  if (type === PostureAlertType.ITEM_05) {
    return '下巴收一点～';
  }
  if (type === PostureAlertType.ITEM_06) {
    return '头别歪～';
  }
  if (type === PostureAlertType.ITEM_07 || type === PostureAlertType.BODY_SLIDE) {
    return '靠回椅背～';
  }
  if (type === PostureAlertType.ITEM_10) {
    return '屏幕抬高一点～';
  }
  if (type === PostureAlertType.ITEM_11 || type === PostureAlertType.MOUTH_OPEN) {
    return '嘴巴轻合～';
  }
  if (type === PostureAlertType.ITEM_12) {
    return '呼吸一下～';
  }
  return '坐直了';
}

export function alertTypeSubtitle(type: PostureAlertType): string {
  if (type === PostureAlertType.ITEM_01 || type === PostureAlertType.KYPHOSIS) {
    return '驼背了，背轻轻靠回椅背';
  }
  if (type === PostureAlertType.ITEM_02 || type === PostureAlertType.SHOULDER_TILT) {
    return '身体别歪向一侧，重心放中间';
  }
  if (type === PostureAlertType.ITEM_03 || type === PostureAlertType.HEAD_DROP) {
    return '视线太低了，让屏幕和眼睛齐平';
  }
  if (type === PostureAlertType.ITEM_05) {
    return '别把脖子探出去';
  }
  if (type === PostureAlertType.ITEM_06) {
    return '头部尽量保持居中';
  }
  if (type === PostureAlertType.ITEM_07 || type === PostureAlertType.BODY_SLIDE) {
    return '腰背需要更多支撑';
  }
  if (type === PostureAlertType.ITEM_10) {
    return '别总低头看屏幕';
  }
  if (type === PostureAlertType.ITEM_11 || type === PostureAlertType.MOUTH_OPEN) {
    return '长时间张嘴要稍微放松闭合';
  }
  if (type === PostureAlertType.ITEM_12) {
    return '坐久了，放松身体深呼吸。顺便检查一下双脚是否平放在地面上。';
  }
  return '姿态偏离有点久，坐直一下';
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
