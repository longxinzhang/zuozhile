import { PostureLevel, ReminderAction } from '../models/PostureTypes';

export const SURFACE: ResourceColor = $r('app.color.surface');
export const SOFT: ResourceColor = $r('app.color.soft');
export const INK: ResourceColor = $r('app.color.ink');
export const MUTED: ResourceColor = $r('app.color.muted');
export const LINE: ResourceColor = $r('app.color.line');
export const GREEN: ResourceColor = $r('app.color.green');
export const GREEN_SOFT: ResourceColor = $r('app.color.green_soft');
export const YELLOW: ResourceColor = $r('app.color.yellow');
export const YELLOW_SOFT: ResourceColor = $r('app.color.yellow_soft');
export const RED: ResourceColor = $r('app.color.red');
export const RED_SOFT: ResourceColor = $r('app.color.red_soft');
export const BLUE: ResourceColor = $r('app.color.blue');
export const BLUE_SOFT: ResourceColor = $r('app.color.blue_soft');
export const APP_BG: ResourceColor = $r('app.color.app_bg');
export const APP_BG_MIST: ResourceColor = $r('app.color.app_bg_mist');
export const GLASS: ResourceColor = $r('app.color.glass');
export const GLASS_SOFT: ResourceColor = $r('app.color.glass_soft');
export const GLASS_GREEN: ResourceColor = $r('app.color.glass_green');
export const GLASS_BLUE: ResourceColor = $r('app.color.glass_blue');
export const BORDER_GLASS: ResourceColor = $r('app.color.border_glass');
export const LINE_SOFT: ResourceColor = $r('app.color.line_soft');
export const GREEN_DEEP: ResourceColor = $r('app.color.green_deep');
export const AMBER_SOFT: ResourceColor = $r('app.color.amber_soft');
export const CORAL: ResourceColor = $r('app.color.coral');
export const CORAL_SOFT: ResourceColor = $r('app.color.coral_soft');
export const SHADOW_CARD: ResourceColor = $r('app.color.shadow_card');
export const SHADOW_GREEN: ResourceColor = $r('app.color.shadow_green');
export const SHADOW_BLUE: ResourceColor = $r('app.color.shadow_blue');
export const SHADOW_CORAL: ResourceColor = $r('app.color.shadow_coral');
export const ACTION_GREEN: ResourceColor = $r('app.color.action_green');
export const ACTION_RED: ResourceColor = $r('app.color.action_red');

export function levelText(level: PostureLevel): string {
  if (level === PostureLevel.GOOD) {
    return '正常';
  }
  if (level === PostureLevel.WARN) {
    return '注意';
  }
  if (level === PostureLevel.BAD) {
    return '纠正';
  }
  return '待识别';
}

export function levelColor(level: PostureLevel): ResourceColor {
  if (level === PostureLevel.GOOD) {
    return GREEN;
  }
  if (level === PostureLevel.WARN) {
    return YELLOW;
  }
  if (level === PostureLevel.BAD) {
    return RED;
  }
  return MUTED;
}

export function levelSoftColor(level: PostureLevel): ResourceColor {
  if (level === PostureLevel.GOOD) {
    return GREEN_SOFT;
  }
  if (level === PostureLevel.WARN) {
    return YELLOW_SOFT;
  }
  if (level === PostureLevel.BAD) {
    return RED_SOFT;
  }
  return GLASS_SOFT;
}

export function reminderColor(action: ReminderAction): ResourceColor {
  if (action === ReminderAction.HARD) {
    return RED;
  }
  if (action === ReminderAction.SOFT) {
    return YELLOW;
  }
  return GREEN;
}

export function scoreColor(score: number): ResourceColor {
  if (score >= 85) {
    return GREEN;
  }
  if (score >= 70) {
    return YELLOW;
  }
  return RED;
}
