import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  AppData,
  CalibrationProfile,
  PostureAlertType,
  PostureLevel,
  ReminderAction,
  SENSITIVE_SENSITIVITY,
  SessionRecord,
  STANDARD_SENSITIVITY,
  UserSettings,
  createDefaultData,
  createDefaultSettings
} from '../models/PostureTypes';

const STORE_NAME = 'zuozhile_session';
const KEY_DATA = 'app_data';
const MAX_RECORDS = 1200;

function numberOr(value: number, fallback: number, min: number, max: number): number {
  if (!Number.isFinite(value)) {
    return fallback;
  }
  if (value < min || value > max) {
    return fallback;
  }
  return value;
}

function normalizeSensitivity(value: number, fallback: number): number {
  const safeValue = numberOr(value, fallback, 0.6, 1.4);
  return safeValue > 1.05 ? SENSITIVE_SENSITIVITY : STANDARD_SENSITIVITY;
}

function sanitizeProfile(profile: CalibrationProfile): CalibrationProfile {
  const defaults = createDefaultSettings().profile;
  if (!profile) {
    return defaults;
  }
  return {
    neutralNeckAngle: numberOr(profile.neutralNeckAngle, defaults.neutralNeckAngle, 0, 45),
    neutralShoulderTilt: numberOr(profile.neutralShoulderTilt, defaults.neutralShoulderTilt, 0, 0.5),
    neutralPitch: numberOr(profile.neutralPitch, defaults.neutralPitch, -45, 45),
    neutralRoll: numberOr(profile.neutralRoll, defaults.neutralRoll, -45, 45),
    neutralYaw: numberOr(profile.neutralYaw, defaults.neutralYaw, -45, 45),
    neutralMouthRatio: numberOr(profile.neutralMouthRatio, defaults.neutralMouthRatio, 0, 0.8),
    neutralFaceCenterY: numberOr(profile.neutralFaceCenterY, defaults.neutralFaceCenterY, 0, 10000),
    neutralFaceHeight: numberOr(profile.neutralFaceHeight, defaults.neutralFaceHeight, 1, 10000),
    neutralFaceArea: numberOr(profile.neutralFaceArea, defaults.neutralFaceArea, 1, 100000000),
    neutralShoulderMidY: numberOr(profile.neutralShoulderMidY, defaults.neutralShoulderMidY, 0, 10000),
    neutralShoulderWidth: numberOr(profile.neutralShoulderWidth, defaults.neutralShoulderWidth, 1, 10000),
    neutralNoseToShoulderRatio: numberOr(profile.neutralNoseToShoulderRatio, defaults.neutralNoseToShoulderRatio, -5, 5),
    calibratedAt: numberOr(profile.calibratedAt, defaults.calibratedAt, 0, 4102444800000),
    sensitivity: normalizeSensitivity(profile.sensitivity, defaults.sensitivity),
    sampleIntervalMs: numberOr(profile.sampleIntervalMs, defaults.sampleIntervalMs, 2000, 10000)
  };
}

function sanitizeSettings(settings: UserSettings): UserSettings {
  const defaults = createDefaultSettings();
  if (!settings) {
    return defaults;
  }
  return {
    profile: sanitizeProfile(settings.profile),
    useCoreVision: settings.useCoreVision === true,
    privacyMode: settings.privacyMode !== false,
    gentleSound: settings.gentleSound === true,
    vibration: settings.vibration !== false
  };
}

function sanitizeLevel(level: PostureLevel): PostureLevel {
  if (level === PostureLevel.GOOD || level === PostureLevel.WARN || level === PostureLevel.BAD ||
    level === PostureLevel.UNKNOWN) {
    return level;
  }
  return PostureLevel.UNKNOWN;
}

function sanitizeAction(action: ReminderAction): ReminderAction {
  if (action === ReminderAction.SOFT || action === ReminderAction.HARD) {
    return action;
  }
  return ReminderAction.NONE;
}

function sanitizeAlertType(type: PostureAlertType): PostureAlertType {
  if (type === PostureAlertType.ITEM_01 || type === PostureAlertType.ITEM_02 ||
    type === PostureAlertType.ITEM_03 || type === PostureAlertType.ITEM_05 ||
    type === PostureAlertType.ITEM_06 || type === PostureAlertType.ITEM_07 ||
    type === PostureAlertType.ITEM_10 || type === PostureAlertType.ITEM_11 ||
    type === PostureAlertType.ITEM_12) {
    return type;
  }
  if (type === PostureAlertType.HEAD_DROP) {
    return PostureAlertType.ITEM_03;
  }
  if (type === PostureAlertType.BODY_SLIDE) {
    return PostureAlertType.ITEM_07;
  }
  if (type === PostureAlertType.KYPHOSIS) {
    return PostureAlertType.ITEM_01;
  }
  if (type === PostureAlertType.SHOULDER_TILT) {
    return PostureAlertType.ITEM_02;
  }
  if (type === PostureAlertType.MOUTH_OPEN) {
    return PostureAlertType.ITEM_11;
  }
  return PostureAlertType.NONE;
}

function sanitizeRecord(record: SessionRecord): SessionRecord {
  return {
    timestamp: typeof record.timestamp === 'number' ? record.timestamp : Date.now(),
    score: numberOr(record.score, 0, 0, 100),
    sitLevel: sanitizeLevel(record.sitLevel),
    chinLevel: sanitizeLevel(record.chinLevel),
    mouthLevel: sanitizeLevel(record.mouthLevel),
    action: sanitizeAction(record.action),
    alertType: sanitizeAlertType(record.alertType)
  };
}

function sanitizeData(data: AppData): AppData {
  const defaults = createDefaultData();
  if (!data) {
    return defaults;
  }
  const rawRecords = data.records ? data.records : [];
  const records = rawRecords.map((record: SessionRecord) => sanitizeRecord(record)).slice(0, MAX_RECORDS);
  return {
    settings: sanitizeSettings(data.settings),
    records,
    lastUpdatedAt: typeof data.lastUpdatedAt === 'number' ? data.lastUpdatedAt : Date.now()
  };
}

export class PostureSessionStore {
  static async load(context: common.UIAbilityContext): Promise<AppData> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      const raw = await store.get(KEY_DATA, '');
      if (typeof raw === 'string' && raw.length > 0) {
        return sanitizeData(JSON.parse(raw) as AppData);
      }
    } catch (error) {
      return createDefaultData();
    }
    return createDefaultData();
  }

  static async save(context: common.UIAbilityContext, data: AppData): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      const next = sanitizeData(data);
      await store.put(KEY_DATA, JSON.stringify(next));
      await store.flush();
    } catch (error) {
    }
  }

  static async clear(context: common.UIAbilityContext): Promise<void> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      await store.delete(KEY_DATA);
      await store.flush();
    } catch (error) {
    }
  }
}
