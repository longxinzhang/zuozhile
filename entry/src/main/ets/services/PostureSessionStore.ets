import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import {
  AppData,
  CalibrationProfile,
  MAX_SESSION_RECORDS,
  PostureAlertType,
  PostureLevel,
  ReminderAction,
  SENSITIVE_SENSITIVITY,
  SessionRecord,
  STANDARD_SENSITIVITY,
  UserSettings,
  WearableReminderRoute,
  createDefaultData,
  createDefaultSettings
} from '../models/PostureTypes';
import { WEARABLE_DIAGNOSTIC_TTL_MS, WearableDiagnostic, WearableLocalState,
  WearableTestConfirmation, wearableUtf8 } from '../models/WearableReminderPolicy';

const STORE_NAME = 'zuozhile_session';
const KEY_DATA = 'app_data';
const KEY_WEARABLE = 'wearable_local';
const SAMPLE_INTERVAL_OPTIONS: number[] = [2000, 3000, 5000];

export interface StoreLoadResult {
  data: AppData;
  isHealthy: boolean;
}

function numberOr(value: number, fallback: number, min: number, max: number): number {
  if (!Number.isFinite(value)) {
    return fallback;
  }
  if (value < min || value > max) {
    return fallback;
  }
  return value;
}

function timestampOr(value: number, fallback: number): number {
  return numberOr(value, fallback, 0, 4102444800000);
}

function normalizeSensitivity(value: number, fallback: number): number {
  const safeValue = numberOr(value, fallback, 0.6, 1.4);
  return safeValue > 1.05 ? SENSITIVE_SENSITIVITY : STANDARD_SENSITIVITY;
}

function normalizeSampleInterval(value: number, fallback: number): number {
  const safeFallback = SAMPLE_INTERVAL_OPTIONS.includes(fallback) ? fallback : 3000;
  if (!Number.isFinite(value) || value < 1000 || value > 10000) {
    return safeFallback;
  }
  let selected = SAMPLE_INTERVAL_OPTIONS[0];
  SAMPLE_INTERVAL_OPTIONS.forEach((option: number) => {
    if (Math.abs(option - value) < Math.abs(selected - value)) {
      selected = option;
    }
  });
  return selected;
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
    neutralLipGapRatio: profile.neutralLipGapRatio !== undefined && Number.isFinite(profile.neutralLipGapRatio) &&
      profile.neutralLipGapRatio >= 0 && profile.neutralLipGapRatio <= 1 ? profile.neutralLipGapRatio : undefined,
    neutralFaceCenterY: numberOr(profile.neutralFaceCenterY, defaults.neutralFaceCenterY, 0, 10000),
    neutralFaceHeight: numberOr(profile.neutralFaceHeight, defaults.neutralFaceHeight, 1, 10000),
    neutralFaceArea: numberOr(profile.neutralFaceArea, defaults.neutralFaceArea, 1, 100000000),
    neutralShoulderMidY: numberOr(profile.neutralShoulderMidY, defaults.neutralShoulderMidY, 0, 10000),
    neutralShoulderWidth: numberOr(profile.neutralShoulderWidth, defaults.neutralShoulderWidth, 1, 10000),
    neutralNoseToShoulderRatio: numberOr(profile.neutralNoseToShoulderRatio, defaults.neutralNoseToShoulderRatio, -5, 5),
    calibratedAt: timestampOr(profile.calibratedAt, defaults.calibratedAt),
    sensitivity: normalizeSensitivity(profile.sensitivity, defaults.sensitivity),
    sampleIntervalMs: normalizeSampleInterval(profile.sampleIntervalMs, defaults.sampleIntervalMs)
  };
}

function sanitizeSettings(settings: UserSettings): UserSettings {
  const defaults = createDefaultSettings();
  if (!settings) {
    return defaults;
  }
  return {
    profile: sanitizeProfile(settings.profile),
    useCoreVision: settings.useCoreVision !== false,
    privacyMode: settings.privacyMode !== false,
    gentleSound: settings.gentleSound === true,
    vibration: settings.vibration !== false,
    lowScoreEdgeLight: settings.lowScoreEdgeLight !== false,
    reduceReminderMotion: settings.reduceReminderMotion === true,
    wearableReminder: settings.wearableReminder === true,
    wearableReminderRoute: settings.wearableReminderRoute === WearableReminderRoute.WEAR_ENGINE ?
      WearableReminderRoute.WEAR_ENGINE : WearableReminderRoute.NOTIFICATION_SYNC
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
  const now = Date.now();
  if (!record) {
    return {
      timestamp: now,
      score: 0,
      sitLevel: PostureLevel.UNKNOWN,
      chinLevel: PostureLevel.UNKNOWN,
      mouthLevel: PostureLevel.UNKNOWN,
      action: ReminderAction.NONE,
      alertType: PostureAlertType.NONE
    };
  }
  return {
    timestamp: timestampOr(record.timestamp, now),
    score: numberOr(record.score, 0, 0, 100),
    sitLevel: sanitizeLevel(record.sitLevel),
    chinLevel: sanitizeLevel(record.chinLevel),
    mouthLevel: sanitizeLevel(record.mouthLevel),
    action: sanitizeAction(record.action),
    alertType: sanitizeAlertType(record.alertType)
  };
}

function sanitizeWearableDiagnostics(raw: string): WearableDiagnostic[] {
  if (raw.length > 131072) {
    return [];
  }
  try {
    const parsed: WearableDiagnostic[] = JSON.parse(raw);
    if (!Array.isArray(parsed)) {
      return [];
    }
    const now = Date.now();
    const result: WearableDiagnostic[] = [];
    parsed.slice(0, 100).forEach((source: WearableDiagnostic): void => {
      if (!source || typeof source !== 'object' || typeof source.eventId !== 'string' ||
        source.eventId.length === 0 || !Number.isFinite(source.timestamp) || source.timestamp <= 0 ||
        source.timestamp > now || now - source.timestamp > WEARABLE_DIAGNOSTIC_TTL_MS) {
        return;
      }
      const diagnostic = new WearableDiagnostic();
      diagnostic.eventId = wearableUtf8(source.eventId, 120);
      if (result.some((entry: WearableDiagnostic): boolean => entry.eventId === diagnostic.eventId)) {
        return;
      }
      diagnostic.timestamp = source.timestamp;
      diagnostic.isTest = source.isTest === true;
      diagnostic.route = source.route === WearableReminderRoute.NOTIFICATION_SYNC ?
        WearableReminderRoute.NOTIFICATION_SYNC : WearableReminderRoute.WEAR_ENGINE;
      diagnostic.result = typeof source.result === 'string' ? wearableUtf8(source.result, 120) : '';
      diagnostic.errorCode = numberOr(source.errorCode, 0, 0, Number.MAX_SAFE_INTEGER);
      diagnostic.action = numberOr(source.action, -1, -1, 2);
      diagnostic.feedback = typeof source.feedback === 'string' ? wearableUtf8(source.feedback, 120) : '';
      diagnostic.feedbackErrorCode = numberOr(source.feedbackErrorCode, 0, 0, Number.MAX_SAFE_INTEGER);
      diagnostic.submitted = source.submitted === true;
      if (diagnostic.isTest && diagnostic.submitted && (source.confirmation === WearableTestConfirmation.VIBRATED ||
        source.confirmation === WearableTestConfirmation.DISPLAYED ||
        source.confirmation === WearableTestConfirmation.NOT_RECEIVED)) {
        diagnostic.confirmation = source.confirmation;
      }
      result.push(diagnostic);
    });
    return result.sort((first: WearableDiagnostic, second: WearableDiagnostic): number => second.timestamp - first.timestamp);
  } catch (error) {
    return [];
  }
}

function sanitizeData(data: AppData): AppData {
  const defaults = createDefaultData();
  if (!data) {
    return defaults;
  }
  const rawRecords = Array.isArray(data.records) ? data.records : [];
  const records = rawRecords.map((record: SessionRecord) => sanitizeRecord(record)).slice(0, MAX_SESSION_RECORDS);
  return {
    settings: sanitizeSettings(data.settings),
    records,
    lastUpdatedAt: timestampOr(data.lastUpdatedAt, Date.now())
  };
}

export class PostureSessionStore {
  private static wearableQueue: Promise<boolean> = Promise.resolve(true);

  static async loadWearable(context: common.UIAbilityContext): Promise<WearableLocalState> {
    const result = new WearableLocalState();
    try {
      await PostureSessionStore.wearableQueue;
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      const attempt = store.getSync(KEY_WEARABLE + '_attempt', 0);
      const uptime = store.getSync(KEY_WEARABLE + '_uptime', 0);
      const testAt = store.getSync(KEY_WEARABLE + '_test_at', 0);
      const testRoute = store.getSync(KEY_WEARABLE + '_test_route', '');
      const eventId = store.getSync(KEY_WEARABLE + '_test_event', '');
      const submitted = store.getSync(KEY_WEARABLE + '_test_submitted', true);
      result.lastAttemptAt = typeof attempt === 'number' ? timestampOr(attempt, Date.now()) : Date.now();
      result.lastAttemptUptime = typeof uptime === 'number' ?
        numberOr(uptime, Number.MAX_SAFE_INTEGER, 0, Number.MAX_SAFE_INTEGER) : Number.MAX_SAFE_INTEGER;
      result.testAt = typeof testAt === 'number' ? timestampOr(testAt, 0) : 0;
      result.testRoute = testRoute === WearableReminderRoute.NOTIFICATION_SYNC ?
        WearableReminderRoute.NOTIFICATION_SYNC : WearableReminderRoute.WEAR_ENGINE;
      result.testEventId = typeof eventId === 'string' ? wearableUtf8(eventId, 120) : '';
      result.testSubmitted = submitted === true && result.testAt > 0;
      const outcome = store.getSync(KEY_WEARABLE + '_test_result', '');
      const feedback = store.getSync(KEY_WEARABLE + '_test_feedback', '');
      const confirmation = store.getSync(KEY_WEARABLE + '_confirmation', '');
      const model = store.getSync(KEY_WEARABLE + '_model', '');
      const software = store.getSync(KEY_WEARABLE + '_software', '');
      result.testResult = typeof outcome === 'string' ? wearableUtf8(outcome, 120) : '';
      result.testFeedback = typeof feedback === 'string' ? wearableUtf8(feedback, 120) : '';
      result.model = typeof model === 'string' ? wearableUtf8(model, 80) : '';
      result.softwareVersion = typeof software === 'string' ? wearableUtf8(software, 60) : '';
      if (result.testSubmitted && (confirmation === WearableTestConfirmation.VIBRATED ||
        confirmation === WearableTestConfirmation.DISPLAYED || confirmation === WearableTestConfirmation.NOT_RECEIVED)) {
        result.confirmation = confirmation;
      }
      if (result.testAt <= 0 || Date.now() - result.testAt > 86400000 || result.testAt > Date.now()) {
        result.testAt = 0;
        result.testEventId = '';
        result.testSubmitted = false;
        result.testResult = '';
        result.testFeedback = '';
        result.confirmation = WearableTestConfirmation.UNCONFIRMED;
        result.model = '';
        result.softwareVersion = '';
      }
      const diagnostics = store.getSync(KEY_WEARABLE + '_diagnostics', '');
      result.diagnostics = typeof diagnostics === 'string' ? sanitizeWearableDiagnostics(diagnostics) : [];
      if (result.testAt > 0 && result.testEventId.length === 0) {
        result.testEventId = 'legacy-test:' + result.testAt.toString();
        const migrated = new WearableDiagnostic();
        migrated.eventId = result.testEventId;
        migrated.timestamp = result.testAt;
        migrated.isTest = true;
        migrated.route = result.testRoute;
        migrated.result = result.testResult;
        migrated.feedback = result.testFeedback;
        migrated.submitted = result.testSubmitted;
        migrated.confirmation = result.confirmation;
        if (!result.diagnostics.some((item: WearableDiagnostic): boolean => item.eventId === migrated.eventId)) {
          result.diagnostics.push(migrated);
          result.diagnostics = result.diagnostics.sort((first: WearableDiagnostic, second: WearableDiagnostic): number =>
            second.timestamp - first.timestamp).slice(0, 100);
        }
      }
    } catch (error) {
      result.lastAttemptAt = Date.now();
      result.lastAttemptUptime = Number.MAX_SAFE_INTEGER;
    }
    return result;
  }

  static saveWearable(context: common.UIAbilityContext, state: WearableLocalState): Promise<boolean> {
    const snapshot = new WearableLocalState();
    snapshot.lastAttemptAt = state.lastAttemptAt;
    snapshot.lastAttemptUptime = state.lastAttemptUptime;
    snapshot.testAt = state.testAt;
    snapshot.testEventId = state.testEventId;
    snapshot.testSubmitted = state.testSubmitted;
    snapshot.testRoute = state.testRoute;
    snapshot.testResult = state.testResult;
    snapshot.testFeedback = state.testFeedback;
    snapshot.confirmation = state.confirmation;
    snapshot.model = state.model;
    snapshot.softwareVersion = state.softwareVersion;
    snapshot.diagnostics = sanitizeWearableDiagnostics(JSON.stringify(state.diagnostics));
    PostureSessionStore.wearableQueue = PostureSessionStore.wearableQueue.then(async (): Promise<boolean> => {
      try {
        const store = await preferences.getPreferences(context, { name: STORE_NAME });
        store.putSync(KEY_WEARABLE + '_attempt', snapshot.lastAttemptAt);
        store.putSync(KEY_WEARABLE + '_uptime', snapshot.lastAttemptUptime);
        store.putSync(KEY_WEARABLE + '_test_at', snapshot.testAt);
        store.putSync(KEY_WEARABLE + '_test_event', snapshot.testEventId);
        store.putSync(KEY_WEARABLE + '_test_submitted', snapshot.testSubmitted);
        store.putSync(KEY_WEARABLE + '_test_route', snapshot.testRoute);
        store.putSync(KEY_WEARABLE + '_test_result', wearableUtf8(snapshot.testResult, 120));
        store.putSync(KEY_WEARABLE + '_test_feedback', wearableUtf8(snapshot.testFeedback, 120));
        store.putSync(KEY_WEARABLE + '_confirmation', snapshot.confirmation);
        store.putSync(KEY_WEARABLE + '_model', wearableUtf8(snapshot.model, 80));
        store.putSync(KEY_WEARABLE + '_software', wearableUtf8(snapshot.softwareVersion, 60));
        store.putSync(KEY_WEARABLE + '_diagnostics', JSON.stringify(snapshot.diagnostics));
        await store.flush();
        return true;
      } catch (error) {
        return false;
      }
    });
    return PostureSessionStore.wearableQueue;
  }

  static async loadWithStatus(context: common.UIAbilityContext): Promise<StoreLoadResult> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      const raw = await store.get(KEY_DATA, '');
      if (typeof raw === 'string' && raw.length > 0) {
        return {
          data: sanitizeData(JSON.parse(raw) as AppData),
          isHealthy: true
        };
      }
    } catch (error) {
      return {
        data: createDefaultData(),
        isHealthy: false
      };
    }
    return {
      data: createDefaultData(),
      isHealthy: true
    };
  }

  static async load(context: common.UIAbilityContext): Promise<AppData> {
    const result = await PostureSessionStore.loadWithStatus(context);
    return result.data;
  }

  static async save(context: common.UIAbilityContext, data: AppData): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      const next = sanitizeData(data);
      await store.put(KEY_DATA, JSON.stringify(next));
      await store.flush();
      return true;
    } catch (error) {
      return false;
    }
  }

  static async clear(context: common.UIAbilityContext): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      await store.delete(KEY_DATA);
      await store.flush();
      return true;
    } catch (error) {
      return false;
    }
  }
}
