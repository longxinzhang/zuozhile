import { PostureLevel, ReminderAction } from '../models/PostureTypes';

export const SURFACE = '#FFFFFF';
export const SOFT = '#F3F5F8';
export const INK = '#20252D';
export const MUTED = '#737D89';
export const LINE = '#E1E5EB';
export const GREEN = '#168756';
export const GREEN_SOFT = '#E8F6EE';
export const YELLOW = '#B46F00';
export const YELLOW_SOFT = '#FFF3D7';
export const RED = '#C23B32';
export const RED_SOFT = '#FFE9E6';
export const BLUE = '#2457A6';
export const BLUE_SOFT = '#EAF1FF';
export const APP_BG = '#F2F3F5';
export const APP_BG_MIST = '#EDF2F6';
export const GLASS = '#FCFFFFFF';
export const GLASS_SOFT = '#F1F2F4';
export const GLASS_GREEN = '#EFF9F3';
export const GLASS_BLUE = '#EFF6FF';
export const BORDER_GLASS = '#FFFFFF';
export const LINE_SOFT = '#E6EAF0';
export const GREEN_DEEP = '#0F6B3F';
export const AMBER_SOFT = '#FFF1CF';
export const CORAL = '#EB6155';
export const CORAL_SOFT = '#FFE7E2';
export const SHADOW_CARD = '#06273951';
export const SHADOW_GREEN = '#1416834F';
export const SHADOW_BLUE = '#183C608C';
export const SHADOW_CORAL = '#36D9463E';

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

export function levelColor(level: PostureLevel): string {
  if (level === PostureLevel.GOOD) {
    return GREEN;
  }
  if (level === PostureLevel.WARN) {
    return YELLOW;
  }
  if (level === PostureLevel.BAD) {
    return RED;
  }
  return BLUE;
}

export function levelSoftColor(level: PostureLevel): string {
  if (level === PostureLevel.GOOD) {
    return GREEN_SOFT;
  }
  if (level === PostureLevel.WARN) {
    return YELLOW_SOFT;
  }
  if (level === PostureLevel.BAD) {
    return RED_SOFT;
  }
  return BLUE_SOFT;
}

export function reminderColor(action: ReminderAction): string {
  if (action === ReminderAction.HARD) {
    return RED;
  }
  if (action === ReminderAction.SOFT) {
    return YELLOW;
  }
  return GREEN;
}

export function scoreColor(score: number): string {
  if (score >= 85) {
    return GREEN;
  }
  if (score >= 70) {
    return YELLOW;
  }
  return RED;
}
