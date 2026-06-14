export enum PostureLevel {
  GOOD = 'good',
  WARN = 'warn',
  BAD = 'bad',
  UNKNOWN = 'unknown'
}

export enum ReminderAction {
  NONE = 'none',
  SOFT = 'soft',
  HARD = 'hard'
}

export const STANDARD_SENSITIVITY = 0.9;
export const SENSITIVE_SENSITIVITY = 1.2;
export const MAX_SESSION_RECORDS = 1200;

export enum PostureAlertType {
  NONE = 'none',
  ITEM_01 = 'ITEM_01',
  ITEM_02 = 'ITEM_02',
  ITEM_03 = 'ITEM_03',
  ITEM_05 = 'ITEM_05',
  ITEM_06 = 'ITEM_06',
  ITEM_07 = 'ITEM_07',
  ITEM_10 = 'ITEM_10',
  ITEM_11 = 'ITEM_11',
  ITEM_12 = 'ITEM_12',
  HEAD_DROP = 'D1_HEAD_DROP',
  BODY_SLIDE = 'D2_BODY_SLIDE',
  KYPHOSIS = 'D3_KYPHOSIS',
  SHOULDER_TILT = 'D4_SHOULDER_TILT',
  MOUTH_OPEN = 'D5_MOUTH_OPEN'
}

export interface Point2D {
  x: number;
  y: number;
  score: number;
}

export interface SkeletonFrame {
  nose?: Point2D;
  leftEar?: Point2D;
  rightEar?: Point2D;
  leftShoulder?: Point2D;
  rightShoulder?: Point2D;
  leftHip?: Point2D;
  rightHip?: Point2D;
}

export interface FaceRect {
  left: number;
  top: number;
  width: number;
  height: number;
}

export interface FaceFrame {
  yaw: number;
  pitch: number;
  roll: number;
  mouthOpenRatio: number;
  confidence: number;
  rect?: FaceRect;
}

export interface PostureSample {
  timestamp: number;
  skeleton: SkeletonFrame;
  face: FaceFrame;
}

export interface CalibrationProfile {
  neutralNeckAngle: number;
  neutralShoulderTilt: number;
  neutralPitch: number;
  neutralRoll: number;
  neutralYaw: number;
  neutralMouthRatio: number;
  neutralFaceCenterY: number;
  neutralFaceHeight: number;
  neutralFaceArea: number;
  neutralShoulderMidY: number;
  neutralShoulderWidth: number;
  neutralNoseToShoulderRatio: number;
  calibratedAt: number;
  sensitivity: number;
  sampleIntervalMs: number;
}

export interface MetricResult {
  level: PostureLevel;
  value: number;
  baseline: number;
  score: number;
  label: string;
  alertType: PostureAlertType;
}

export interface PostureResult {
  timestamp: number;
  sit: MetricResult;
  chin: MetricResult;
  mouth: MetricResult;
  score: number;
  summary: string;
  action: ReminderAction;
  activeAlerts: PostureAlertType[];
  primaryAlert: PostureAlertType;
}

export interface SessionRecord {
  timestamp: number;
  score: number;
  sitLevel: PostureLevel;
  chinLevel: PostureLevel;
  mouthLevel: PostureLevel;
  action: ReminderAction;
  alertType: PostureAlertType;
}

export interface UserSettings {
  profile: CalibrationProfile;
  useCoreVision: boolean;
  privacyMode: boolean;
  gentleSound: boolean;
  vibration: boolean;
}

export interface AppData {
  settings: UserSettings;
  records: SessionRecord[];
  lastUpdatedAt: number;
}

export interface TodayStats {
  sampleCount: number;
  uprightCount: number;
  warnCount: number;
  badCount: number;
  remindCount: number;
  averageScore: number;
  guardedMinutes: number;
  uprightMinutes: number;
}

export interface AlertBreakdownItem {
  type: PostureAlertType;
  count: number;
  percent: number;
}

export function createDefaultCalibration(): CalibrationProfile {
  return {
    neutralNeckAngle: 7,
    neutralShoulderTilt: 0.02,
    neutralPitch: 0,
    neutralRoll: 0,
    neutralYaw: 0,
    neutralMouthRatio: 0.16,
    neutralFaceCenterY: 0,
    neutralFaceHeight: 1,
    neutralFaceArea: 1,
    neutralShoulderMidY: 0,
    neutralShoulderWidth: 1,
    neutralNoseToShoulderRatio: 0.8,
    calibratedAt: 0,
    sensitivity: STANDARD_SENSITIVITY,
    sampleIntervalMs: 3000
  };
}

export function createDefaultSettings(): UserSettings {
  return {
    profile: createDefaultCalibration(),
    useCoreVision: true,
    privacyMode: true,
    gentleSound: false,
    vibration: true
  };
}

export function createDefaultData(): AppData {
  return {
    settings: createDefaultSettings(),
    records: [],
    lastUpdatedAt: Date.now()
  };
}
