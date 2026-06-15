import { PostureLevel, ReminderAction } from '../models/PostureTypes';

export const SURFACE = '#FFFFFF';
export const SOFT = '#F6F7F2';
export const INK = '#171B1A';
export const MUTED = '#68716E';
export const LINE = '#DDE3DB';
export const GREEN = '#167C4A';
export const GREEN_SOFT = '#E8F6EE';
export const YELLOW = '#B46F00';
export const YELLOW_SOFT = '#FFF3D7';
export const RED = '#C23B32';
export const RED_SOFT = '#FFE9E6';
export const BLUE = '#2457A6';
export const BLUE_SOFT = '#EAF1FF';
export const APP_BG = '#F2F7F3';
export const APP_BG_MIST = '#EEF6F2';
export const GLASS = '#FDFEFA';
export const GLASS_SOFT = '#F8FCF8';
export const GLASS_GREEN = '#F0FBF5';
export const GLASS_BLUE = '#EFF6FF';
export const BORDER_GLASS = '#FFFFFF';
export const LINE_SOFT = '#E7EEE6';
export const GREEN_DEEP = '#0F6B3F';
export const AMBER_SOFT = '#FFF1CF';
export const CORAL = '#D9463E';
export const CORAL_SOFT = '#FFE7E2';
export const SHADOW_CARD = '#180F251A';
export const SHADOW_GREEN = '#2E16834F';
export const SHADOW_BLUE = '#24528CDC';
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
