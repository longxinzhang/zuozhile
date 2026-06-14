import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { buildCalibrationProfile } from '../models/PostureCalibration';
import { evaluatePosture } from '../models/PostureEvaluator';
import { ReminderEngine, actionLabel, alertTypeLabel, alertTypeSubtitle, alertTypeTitle } from '../models/ReminderEngine';
import { HourBucket, buildAlertBreakdown, buildRecentBuckets, computeTodayStats } from '../models/SessionStats';
import {
  AlertBreakdownItem,
  AppData,
  MAX_SESSION_RECORDS,
  MetricResult,
  PostureAlertType,
  PostureLevel,
  PostureResult,
  PostureSample,
  ReminderAction,
  SENSITIVE_SENSITIVITY,
  SessionRecord,
  STANDARD_SENSITIVITY,
  TodayStats,
  UserSettings,
  createDefaultData,
  createDefaultSettings
} from '../models/PostureTypes';
import { PostureSessionStore } from '../services/PostureSessionStore';
import { BaselineTile, SmallCounter, StatTile } from '../components/StatusTiles';
import { MockPostureSource } from '../services/MockPostureSource';
import { CoreVisionPostureSource } from '../services/CoreVisionPostureSource';
import { GuardWindowService } from '../services/GuardWindowService';
import { ReminderFeedbackService } from '../services/ReminderFeedbackService';
import { PostureSource } from '../services/PostureSource';
import { CameraProbeResult, CameraProbeService } from '../services/CameraProbeService';
import {
  BLUE,
  GREEN,
  GREEN_SOFT,
  INK,
  LINE,
  MUTED,
  RED,
  RED_SOFT,
  SOFT,
  SURFACE,
  YELLOW,
  YELLOW_SOFT,
  levelColor,
  levelSoftColor,
  levelText,
  reminderColor,
  scoreColor
} from '../theme/ZuozhiTheme';

interface TabItem {
  index: number;
  label: string;
}

interface PostureGuideItem {
  id: number;
  title: string;
  subtitle: string;
}

enum DisplayMetricType {
  SIT = 'sit',
  CHIN = 'chin',
  MOUTH = 'mouth'
}

const TABS: TabItem[] = [
  { index: 0, label: '守护' },
  { index: 1, label: '统计' },
  { index: 2, label: '指南' },
  { index: 3, label: '设置' }
];
const GUIDE_ITEMS: PostureGuideItem[] = [
  { id: 1, title: '挺起来一点～', subtitle: '驼背了，背轻轻靠回椅背' },
  { id: 2, title: '坐正一点～', subtitle: '身体别歪向一侧，重心放中间' },
  { id: 3, title: '抬头一点～', subtitle: '视线太低了，让屏幕和眼睛齐平' },
  { id: 4, title: '肩膀放松～', subtitle: '别耸肩，双肩自然下沉' },
  { id: 5, title: '下巴收一点～', subtitle: '别把脖子探出去' },
  { id: 6, title: '头别歪～', subtitle: '头部尽量保持居中' },
  { id: 7, title: '靠回椅背～', subtitle: '腰背需要更多支撑' },
  { id: 8, title: '双脚踩稳～', subtitle: '双脚尽量平放地面' },
  { id: 9, title: '手臂放松～', subtitle: '手肘自然弯曲，不要太紧' },
  { id: 10, title: '屏幕抬高一点～', subtitle: '别总低头看屏幕' },
  { id: 11, title: '嘴巴轻合～', subtitle: '长时间张嘴要稍微放松闭合' },
  { id: 12, title: '呼吸一下～', subtitle: '坐久了，放松身体深呼吸' }
];
const CAMERA_PERMISSION: Permissions = 'ohos.permission.CAMERA';
const CALIBRATION_FRAME_COUNT = 10;
const CALIBRATION_COUNTDOWN_SECONDS = 3;
const CALIBRATION_COUNTDOWN_DELAY_MS = 1000;
const CALIBRATION_SAMPLE_DELAY_MS = 500;
const HARD_REMINDER_TIMEOUT_MS = 8000;
const DISPLAY_STABLE_FRAMES = 2;

@Entry
@Component
struct Index {
  @State private loaded: boolean = false;
  @State private activeTab: number = 0;
  @State private isGuarding: boolean = false;
  @State private isStartingGuard: boolean = false;
  @State private settings: UserSettings = createDefaultSettings();
  @State private records: SessionRecord[] = [];
  @State private score: number = 92;
  @State private summary: string = '坐姿在线';
  @State private sitLevel: PostureLevel = PostureLevel.GOOD;
  @State private chinLevel: PostureLevel = PostureLevel.GOOD;
  @State private mouthLevel: PostureLevel = PostureLevel.GOOD;
  @State private sitLabel: string = '肩颈稳定';
  @State private chinLabel: string = '下巴高度正常';
  @State private mouthLabel: string = '嘴部放松';
  @State private sitValue: number = 7;
  @State private chinValue: number = 0;
  @State private mouthValue: number = 0.16;
  @State private reminderText: string = '暂无提醒';
  @State private reminderAction: ReminderAction = ReminderAction.NONE;
  @State private reminderAlertType: PostureAlertType = PostureAlertType.NONE;
  @State private reminderMessage: string = '';
  @State private showHardReminder: boolean = false;
  @State private showClearDataConfirm: boolean = false;
  @State private showResetCalibrationConfirm: boolean = false;
  @State private showCoreVisionConfirm: boolean = false;
  @State private lastSampleText: string = '尚未采样';
  @State private sourceLabel: string = '真实相机检测';
  @State private sourceDetail: string = '真实相机待启动';
  @State private permissionText: string = '相机权限待授权';
  @State private isCameraPermissionGranted: boolean = false;
  @State private cameraProbeText: string = '相机能力待检测';
  @State private isCameraProbeAvailable: boolean = false;
  @State private cameraPreviewSurfaceId: string = '';
  @State private guardWindowText: string = '守护窗口待开启';
  private timer: number = -1;
  private hardReminderTimer: number = -1;
  private guardRunId: number = 0;
  private isSampling: boolean = false;
  private lastSample?: PostureSample;
  private sitCandidateKey: string = '';
  private sitCandidateCount: number = 0;
  private chinCandidateKey: string = '';
  private chinCandidateCount: number = 0;
  private mouthCandidateKey: string = '';
  private mouthCandidateCount: number = 0;
  private cameraPreviewController: XComponentController = new XComponentController();
  private guardWindow: GuardWindowService = new GuardWindowService();
  private reminder: ReminderEngine = new ReminderEngine();
  private postureSource: PostureSource = new MockPostureSource();
  aboutToAppear(): void {
    if (!this.loaded) {
      this.loadData();
    }
  }
  aboutToDisappear(): void {
    this.stopGuard();
  }
  private abilityContext(): common.UIAbilityContext | undefined {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext) {
      return hostContext as common.UIAbilityContext;
    }
    return undefined;
  }
  private async loadData(): Promise<void> {
    const context = this.abilityContext();
    if (context) {
      const data = await PostureSessionStore.load(context);
      this.applyData(data);
    } else {
      this.applyData(createDefaultData());
    }
    this.loaded = true;
  }
  private applyData(data: AppData): void {
    this.settings = this.copySettings(data.settings);
    this.records = data.records.slice();
    this.syncIdleSourceStatus();
  }
  private copySettings(settings: UserSettings): UserSettings {
    return {
      profile: {
        neutralNeckAngle: settings.profile.neutralNeckAngle,
        neutralShoulderTilt: settings.profile.neutralShoulderTilt,
        neutralPitch: settings.profile.neutralPitch,
        neutralRoll: settings.profile.neutralRoll,
        neutralYaw: settings.profile.neutralYaw,
        neutralMouthRatio: settings.profile.neutralMouthRatio,
        neutralFaceCenterY: settings.profile.neutralFaceCenterY,
        neutralFaceHeight: settings.profile.neutralFaceHeight,
        neutralFaceArea: settings.profile.neutralFaceArea,
        neutralShoulderMidY: settings.profile.neutralShoulderMidY,
        neutralShoulderWidth: settings.profile.neutralShoulderWidth,
        neutralNoseToShoulderRatio: settings.profile.neutralNoseToShoulderRatio,
        calibratedAt: settings.profile.calibratedAt,
        sensitivity: settings.profile.sensitivity,
        sampleIntervalMs: settings.profile.sampleIntervalMs
      },
      useCoreVision: settings.useCoreVision,
      privacyMode: settings.privacyMode,
      gentleSound: settings.gentleSound,
      vibration: settings.vibration
    };
  }
  private persistData(): void {
    const context = this.abilityContext();
    if (!context) {
      return;
    }
    const data: AppData = {
      settings: this.copySettings(this.settings),
      records: this.records.slice(),
      lastUpdatedAt: Date.now()
    };
    PostureSessionStore.save(context, data);
  }
  private async startGuard(): Promise<void> {
    if (this.isGuarding || this.isStartingGuard) {
      return;
    }
    this.isStartingGuard = true;
    this.guardRunId += 1;
    const runId = this.guardRunId;
    try {
      const sourceReady = await this.prepareSourceAccess();
      if (!sourceReady) {
        return;
      }
      await this.rebuildPostureSource();
      if (runId !== this.guardRunId) {
        await this.postureSource.dispose();
        this.syncSourceStatus();
        return;
      }
      const context = this.abilityContext();
      if (context) {
        await this.guardWindow.enter(context);
        this.guardWindowText = this.guardWindow.statusDetail();
      }
      if (runId !== this.guardRunId) {
        await this.postureSource.dispose();
        this.syncSourceStatus();
        return;
      }
      this.isGuarding = true;
      this.reminder.reset();
      this.resetDisplayStability();
      this.resetReminderState('暂无提醒');
      if (this.timer >= 0) {
        clearInterval(this.timer);
        this.timer = -1;
      }
      this.captureFrame();
      this.timer = setInterval(() => {
        this.captureFrame();
      }, this.settings.profile.sampleIntervalMs);
    } finally {
      if (runId === this.guardRunId) {
        this.isStartingGuard = false;
      }
    }
  }
  private async stopGuard(): Promise<void> {
    this.guardRunId += 1;
    this.isStartingGuard = false;
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
    this.isGuarding = false;
    this.resetDisplayStability();
    this.resetReminderState('守护已暂停');
    await this.postureSource.dispose();
    this.isSampling = false;
    await this.guardWindow.leave(this.abilityContext());
    this.guardWindowText = this.guardWindow.statusDetail();
    this.syncSourceStatus();
  }
  private async prepareSourceAccess(): Promise<boolean> {
    if (!this.settings.useCoreVision) {
      this.permissionText = '模拟采样无需相机权限';
      this.cameraProbeText = '模拟采样未占用相机';
      this.isCameraPermissionGranted = false;
      this.isCameraProbeAvailable = false;
      return true;
    }

    if (this.cameraPreviewSurfaceId.length === 0) {
      this.summary = '预览未就绪';
      this.reminderText = '预览 surface 未创建';
      this.sourceDetail = '真实相机需要预览 surface 后才能拍照抽帧';
      return false;
    }
    const permissionGranted = await this.ensureCameraPermission();
    if (!permissionGranted) {
      this.summary = '需要相机权限';
      this.reminderText = '权限未授权';
      return false;
    }
    const cameraReady = this.probeCamera();
    if (!cameraReady) {
      this.summary = '相机不可用';
      this.reminderText = '相机预检失败';
      return false;
    }
    return true;
  }
  private async ensureCameraPermission(): Promise<boolean> {
    const context = this.abilityContext();
    if (!context) {
      this.permissionText = '无法获取权限上下文';
      this.isCameraPermissionGranted = false;
      return false;
    }
    try {
      const manager = abilityAccessCtrl.createAtManager();
      const result = await manager.requestPermissionsFromUser(context, [CAMERA_PERMISSION]);
      const granted = result.authResults.length > 0 &&
        result.authResults[0] === abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED;
      this.isCameraPermissionGranted = granted;
      this.permissionText = granted ? '相机权限已授权' : '相机权限未授权';
      return granted;
    } catch (error) {
      this.permissionText = '相机权限请求失败';
      this.isCameraPermissionGranted = false;
      return false;
    }
  }
  private probeCamera(): boolean {
    const context = this.abilityContext();
    if (!context) {
      this.cameraProbeText = '无法获取相机上下文';
      this.isCameraProbeAvailable = false;
      return false;
    }
    const result: CameraProbeResult = CameraProbeService.probe(context);
    this.isCameraProbeAvailable = result.available;
    if (result.available) {
      this.cameraProbeText = (result.hasFrontCamera ? '前置摄像头可用' : '未找到前置，使用默认摄像头') +
        ' · ' + result.detail;
    } else {
      this.cameraProbeText = result.detail;
    }
    return result.available;
  }
  private syncAccessStatusForSource(): void {
    if (!this.settings.useCoreVision) {
      this.permissionText = '模拟采样无需相机权限';
      this.cameraProbeText = '模拟采样未占用相机';
      this.isCameraPermissionGranted = false;
      this.isCameraProbeAvailable = false;
      return;
    }
    if (this.permissionText === '模拟采样无需相机权限') {
      this.permissionText = '相机权限待授权';
      this.isCameraPermissionGranted = false;
    }
    if (this.cameraProbeText === '模拟采样未占用相机') {
      this.cameraProbeText = '相机能力待检测';
      this.isCameraProbeAvailable = false;
    }
  }
  private async captureFrame(force: boolean = false): Promise<void> {
    if (!force && !this.isGuarding) {
      return;
    }
    if (this.isSampling) {
      return;
    }
    const runId = this.guardRunId;
    this.isSampling = true;
    try {
      const sample = await this.postureSource.sample(this.settings.profile);
      if (!force && (!this.isGuarding || runId !== this.guardRunId)) {
        return;
      }
      this.lastSample = sample;
      const result = evaluatePosture(sample, this.settings.profile);
      const action = this.reminder.feed(result, Date.now());
      result.action = action;
      result.primaryAlert = action === ReminderAction.NONE ? result.primaryAlert : this.reminder.alertType();
      this.applyResult(result);
      this.appendRecord(result);
      this.syncSourceStatus();
    } catch (error) {
      if (!force && (!this.isGuarding || runId !== this.guardRunId)) {
        return;
      }
      this.summary = '采样失败';
      this.reminderText = '检测源异常';
      this.syncSourceStatus();
    } finally {
      this.isSampling = false;
    }
  }
  private metricSeverity(level: PostureLevel): number {
    if (level === PostureLevel.BAD) {
      return 3;
    }
    if (level === PostureLevel.WARN) {
      return 2;
    }
    if (level === PostureLevel.GOOD) {
      return 1;
    }
    return 0;
  }
  private metricKey(level: PostureLevel, label: string, alertType: PostureAlertType): string {
    return level + '|' + label + '|' + alertType;
  }
  private candidateKeyFor(type: DisplayMetricType): string {
    if (type === DisplayMetricType.SIT) {
      return this.sitCandidateKey;
    }
    if (type === DisplayMetricType.CHIN) {
      return this.chinCandidateKey;
    }
    return this.mouthCandidateKey;
  }
  private candidateCountFor(type: DisplayMetricType): number {
    if (type === DisplayMetricType.SIT) {
      return this.sitCandidateCount;
    }
    if (type === DisplayMetricType.CHIN) {
      return this.chinCandidateCount;
    }
    return this.mouthCandidateCount;
  }
  private setCandidate(type: DisplayMetricType, key: string, count: number): void {
    if (type === DisplayMetricType.SIT) {
      this.sitCandidateKey = key;
      this.sitCandidateCount = count;
      return;
    }
    if (type === DisplayMetricType.CHIN) {
      this.chinCandidateKey = key;
      this.chinCandidateCount = count;
      return;
    }
    this.mouthCandidateKey = key;
    this.mouthCandidateCount = count;
  }
  private resetDisplayStability(): void {
    this.sitCandidateKey = '';
    this.sitCandidateCount = 0;
    this.chinCandidateKey = '';
    this.chinCandidateCount = 0;
    this.mouthCandidateKey = '';
    this.mouthCandidateCount = 0;
  }
  private shouldAdoptMetric(
    type: DisplayMetricType,
    nextKey: string,
    nextLevel: PostureLevel,
    currentKey: string,
    currentLevel: PostureLevel
  ): boolean {
    const nextSeverity = this.metricSeverity(nextLevel);
    const currentSeverity = this.metricSeverity(currentLevel);
    if (nextKey === currentKey || nextSeverity < currentSeverity || nextLevel === PostureLevel.GOOD) {
      this.setCandidate(type, '', 0);
      return true;
    }

    const candidateCount = this.candidateKeyFor(type) === nextKey ? this.candidateCountFor(type) + 1 : 1;
    this.setCandidate(type, nextKey, candidateCount);
    return candidateCount >= DISPLAY_STABLE_FRAMES;
  }
  private displaySummary(): string {
    if (this.score >= 88 && this.sitLevel !== PostureLevel.BAD && this.chinLevel !== PostureLevel.BAD &&
      this.mouthLevel !== PostureLevel.BAD) {
      return '坐姿在线';
    }
    if (this.sitLevel === PostureLevel.BAD) {
      return this.sitLabel;
    }
    if (this.chinLevel === PostureLevel.BAD) {
      return this.chinLabel;
    }
    if (this.mouthLevel === PostureLevel.BAD) {
      return this.mouthLabel;
    }
    if (this.score >= 72) {
      return '稍微调整一下';
    }
    return '坐直了';
  }
  private applyResult(result: PostureResult): void {
    const useSit = this.shouldAdoptMetric(
      DisplayMetricType.SIT,
      this.metricKey(result.sit.level, result.sit.label, result.sit.alertType),
      result.sit.level,
      this.metricKey(this.sitLevel, this.sitLabel, this.sitAlertType()),
      this.sitLevel
    );
    const useChin = this.shouldAdoptMetric(
      DisplayMetricType.CHIN,
      this.metricKey(result.chin.level, result.chin.label, result.chin.alertType),
      result.chin.level,
      this.metricKey(this.chinLevel, this.chinLabel,
        this.chinLevel === PostureLevel.GOOD ? PostureAlertType.NONE : this.chinAlertType()),
      this.chinLevel
    );
    const useMouth = this.shouldAdoptMetric(
      DisplayMetricType.MOUTH,
      this.metricKey(result.mouth.level, result.mouth.label, result.mouth.alertType),
      result.mouth.level,
      this.metricKey(this.mouthLevel, this.mouthLabel,
        this.mouthLevel === PostureLevel.GOOD ? PostureAlertType.NONE : PostureAlertType.ITEM_11),
      this.mouthLevel
    );
    this.score = result.score;
    if (useSit) {
      this.applySitMetric(result.sit);
    }
    if (useChin) {
      this.applyChinMetric(result.chin);
    }
    if (useMouth) {
      this.applyMouthMetric(result.mouth);
    }
    this.summary = this.displaySummary();
    if (result.action !== ReminderAction.NONE) {
      this.reminderAction = result.action;
      this.reminderAlertType = result.primaryAlert;
      this.reminderMessage = this.reminderCopy(result.action, result.primaryAlert);
      this.notifyReminder(result.action);
      if (result.action === ReminderAction.HARD) {
        this.showHardReminder = true;
        this.scheduleHardReminderDismiss();
      }
    } else if (result.activeAlerts.length === 0 && this.reminderAction !== ReminderAction.HARD) {
      this.reminderAction = ReminderAction.NONE;
      this.reminderAlertType = PostureAlertType.NONE;
      this.reminderMessage = '';
    }
    this.reminderText = this.reminderAction === ReminderAction.NONE ?
      actionLabel(result.action, result.primaryAlert) :
      actionLabel(this.reminderAction, this.reminderAlertType);
    this.lastSampleText = this.formatClock(result.timestamp);
  }
  private applySitMetric(metric: MetricResult): void {
    this.sitLevel = metric.level;
    this.sitLabel = metric.label;
    this.sitValue = Math.round(metric.value);
  }
  private applyChinMetric(metric: MetricResult): void {
    this.chinLevel = metric.level;
    this.chinLabel = metric.label;
    this.chinValue = Math.round(metric.value);
  }
  private applyMouthMetric(metric: MetricResult): void {
    this.mouthLevel = metric.level;
    this.mouthLabel = metric.label;
    this.mouthValue = Math.round(metric.value * 100) / 100;
  }
  private appendRecord(result: PostureResult): void {
    const record: SessionRecord = {
      timestamp: result.timestamp,
      score: result.score,
      sitLevel: result.sit.level,
      chinLevel: result.chin.level,
      mouthLevel: result.mouth.level,
      action: result.action,
      alertType: result.primaryAlert
    };
    const next = [record].concat(this.records);
    this.records = next.slice(0, MAX_SESSION_RECORDS);
    this.persistData();
  }
  private async calibrateFromCurrent(): Promise<void> {
    if (this.isSampling) {
      return;
    }
    if (this.isGuarding) {
      await this.stopGuard();
    }
    const sourceReady = await this.prepareSourceAccess();
    if (!sourceReady) {
      return;
    }

    this.isSampling = true;
    const samples: PostureSample[] = [];
    try {
      for (let second = CALIBRATION_COUNTDOWN_SECONDS; second > 0; second -= 1) {
        this.summary = second.toString() + '秒后开始校准，请摆好健康姿势';
        this.reminderText = '准备记录健康坐姿基线';
        await this.sleep(CALIBRATION_COUNTDOWN_DELAY_MS);
      }
      await this.rebuildPostureSource();
      for (let index = 0; index < CALIBRATION_FRAME_COUNT; index += 1) {
        this.summary = '开始校准，别乱动哦，' + (index + 1).toString() + '/' + CALIBRATION_FRAME_COUNT.toString();
        this.reminderText = '正在记录健康坐姿基线';
        const sample = await this.postureSource.sample(this.settings.profile);
        this.lastSample = sample;
        samples.push(sample);
        if (index < CALIBRATION_FRAME_COUNT - 1) {
          await this.sleep(CALIBRATION_SAMPLE_DELAY_MS);
        }
      }
      const next = this.copySettings(this.settings);
      next.profile = buildCalibrationProfile(samples, this.settings.profile);
      this.settings = next;
      this.summary = '已记录当前基线';
      this.lastSampleText = this.formatClock(next.profile.calibratedAt);
      this.reminder.reset();
      this.resetDisplayStability();
      this.resetReminderState('暂无提醒');
      this.persistData();
    } catch (error) {
      this.summary = '校准失败';
      this.reminderText = '请确认人脸和上半身在画面内';
    } finally {
      await this.postureSource.dispose();
      this.postureSource = this.createPostureSource();
      this.syncSourceStatus();
      this.isSampling = false;
    }
  }
  private resetCalibration(): void {
    this.showResetCalibrationConfirm = false;
    const defaults = createDefaultSettings();
    const next = this.copySettings(this.settings);
    next.profile.neutralNeckAngle = defaults.profile.neutralNeckAngle;
    next.profile.neutralShoulderTilt = defaults.profile.neutralShoulderTilt;
    next.profile.neutralPitch = defaults.profile.neutralPitch;
    next.profile.neutralRoll = defaults.profile.neutralRoll;
    next.profile.neutralYaw = defaults.profile.neutralYaw;
    next.profile.neutralMouthRatio = defaults.profile.neutralMouthRatio;
    next.profile.neutralFaceCenterY = defaults.profile.neutralFaceCenterY;
    next.profile.neutralFaceHeight = defaults.profile.neutralFaceHeight;
    next.profile.neutralFaceArea = defaults.profile.neutralFaceArea;
    next.profile.neutralShoulderMidY = defaults.profile.neutralShoulderMidY;
    next.profile.neutralShoulderWidth = defaults.profile.neutralShoulderWidth;
    next.profile.neutralNoseToShoulderRatio = defaults.profile.neutralNoseToShoulderRatio;
    next.profile.calibratedAt = defaults.profile.calibratedAt;
    this.settings = next;
    this.summary = '已恢复默认基线';
    this.reminder.reset();
    this.resetDisplayStability();
    this.resetReminderState('暂无提醒');
    this.persistData();
  }
  private requestResetCalibration(): void {
    this.showResetCalibrationConfirm = true;
  }
  private dismissResetCalibrationConfirm(): void {
    this.showResetCalibrationConfirm = false;
  }
  private confirmResetCalibration(): void {
    this.resetCalibration();
  }
  private requestToggleCoreVision(): void {
    this.showCoreVisionConfirm = true;
  }
  private dismissCoreVisionConfirm(): void {
    this.showCoreVisionConfirm = false;
  }
  private async confirmToggleCoreVision(): Promise<void> {
    this.showCoreVisionConfirm = false;
    await this.toggleCoreVision();
  }
  private setSensitivity(value: number): void {
    const next = this.copySettings(this.settings);
    next.profile.sensitivity = value;
    this.settings = next;
    this.reminder.reset();
    this.resetDisplayStability();
    this.resetReminderState('已切换为' + this.sensitivityLabel(value));
    this.persistData();
  }
  private async setIntervalMs(value: number): Promise<void> {
    const next = this.copySettings(this.settings);
    next.profile.sampleIntervalMs = value;
    this.settings = next;
    this.persistData();
    if (this.isGuarding) {
      await this.stopGuard();
      await this.startGuard();
    }
  }
  private async toggleCoreVision(): Promise<void> {
    if (this.isGuarding) {
      await this.stopGuard();
    }
    const next = this.copySettings(this.settings);
    next.useCoreVision = !next.useCoreVision;
    const defaults = createDefaultSettings();
    const sensitivity = next.profile.sensitivity;
    const sampleIntervalMs = next.profile.sampleIntervalMs;
    next.profile = defaults.profile;
    next.profile.sensitivity = sensitivity;
    next.profile.sampleIntervalMs = sampleIntervalMs;
    this.settings = next;
    this.lastSample = undefined;
    this.lastSampleText = '尚未采样';
    this.resetDisplayStability();
    this.persistData();
    await this.rebuildPostureSource();
    this.summary = next.useCoreVision ? '真实检测待开启' : '模拟采样待开启';
    this.reminderText = '已重置基线，请重新记录';
  }
  private togglePrivacy(): void {
    const next = this.copySettings(this.settings);
    next.privacyMode = !next.privacyMode;
    this.settings = next;
    this.persistData();
  }
  private toggleSound(): void {
    const next = this.copySettings(this.settings);
    next.gentleSound = !next.gentleSound;
    this.settings = next;
    this.persistData();
  }
  private toggleVibration(): void {
    const next = this.copySettings(this.settings);
    next.vibration = !next.vibration;
    this.settings = next;
    this.persistData();
  }
  private async clearData(): Promise<void> {
    this.showClearDataConfirm = false;
    await this.stopGuard();
    const context = this.abilityContext();
    if (context) {
      await PostureSessionStore.clear(context);
    }
    const defaults = createDefaultData();
    this.settings = this.copySettings(defaults.settings);
    this.records = [];
    this.reminder.reset();
    this.resetDisplayStability();
    this.score = 92;
    this.summary = '坐姿在线';
    this.resetReminderState('暂无提醒');
    this.lastSampleText = '尚未采样';
    await this.rebuildPostureSource();
  }
  private requestClearData(): void {
    this.showClearDataConfirm = true;
  }
  private dismissClearDataConfirm(): void {
    this.showClearDataConfirm = false;
  }
  private async confirmClearData(): Promise<void> {
    await this.clearData();
  }
  private async sampleOnce(): Promise<void> {
    if (this.isGuarding) {
      await this.captureFrame(true);
      return;
    }
    const sourceReady = await this.prepareSourceAccess();
    if (!sourceReady) {
      return;
    }
    await this.rebuildPostureSource();
    await this.captureFrame(true);
    await this.postureSource.dispose();
    this.syncSourceStatus();
  }
  private createPostureSource(): PostureSource {
    const context = this.abilityContext();
    if (this.settings.useCoreVision && context) {
      return new CoreVisionPostureSource(context, this.cameraPreviewSurfaceId);
    }
    return new MockPostureSource();
  }
  private async rebuildPostureSource(): Promise<void> {
    await this.postureSource.dispose();
    this.postureSource = this.createPostureSource();
    this.syncSourceStatus();
  }
  private syncSourceStatus(): void {
    const status = this.postureSource.status();
    this.sourceLabel = status.label;
    this.sourceDetail = status.detail;
    this.syncAccessStatusForSource();
  }
  private syncIdleSourceStatus(): void {
    this.syncAccessStatusForSource();
    if (this.settings.useCoreVision) {
      this.sourceLabel = '真实相机检测';
      this.sourceDetail = this.cameraPreviewSurfaceId.length > 0 ? '预览 surface 已就绪' : '真实相机待启动';
      return;
    }
    this.sourceLabel = '模拟采样';
    this.sourceDetail = '用于验证 UI、评分和提醒流程';
  }
  private privacyBandTitle(): string {
    return this.settings.privacyMode ? '本机隐私' : '开发诊断';
  }
  private privacyBandCopy(): string {
    if (this.settings.privacyMode) {
      return this.settings.useCoreVision ?
        '图像帧仅在本机内存中用于姿态判断；不显示原始相机画面。' :
        '当前使用模拟采样验证守护流程，不读取相机图像。';
    }
    return this.settings.useCoreVision ?
      '开发诊断已开启：显示相机能力和检测源细节，便于排查采样状态。' :
      '开发诊断已开启：当前使用模拟采样验证守护流程。';
  }
  private cameraProbeDisplayText(): string {
    if (!this.settings.privacyMode || !this.isCameraProbeAvailable) {
      return this.cameraProbeText;
    }
    if (this.cameraProbeText.indexOf('前置摄像头可用') >= 0) {
      return '前置摄像头可用';
    }
    return '相机能力已就绪';
  }
  private previewSurfaceDisplayText(): string {
    if (!this.settings.useCoreVision) {
      return '模拟采样不创建预览';
    }
    return this.cameraPreviewSurfaceId.length > 0 ? '预览 surface 已就绪' : '预览 surface 待创建';
  }
  private previewSurfaceDisplayColor(): string {
    if (!this.settings.useCoreVision || this.cameraPreviewSurfaceId.length > 0) {
      return GREEN;
    }
    return YELLOW;
  }
  private sourceDisplayText(): string {
    if (this.settings.privacyMode) {
      return '当前检测源：' + this.sourceLabel;
    }
    return '当前检测源：' + this.sourceLabel + ' · ' + this.sourceDetail;
  }
  private resetReminderState(text: string): void {
    this.cancelHardReminderTimer();
    this.stopReminderFeedback();
    this.reminderText = text;
    this.reminderAction = ReminderAction.NONE;
    this.reminderAlertType = PostureAlertType.NONE;
    this.reminderMessage = '';
    this.showHardReminder = false;
  }
  private cancelHardReminderTimer(): void {
    if (this.hardReminderTimer >= 0) {
      clearTimeout(this.hardReminderTimer);
      this.hardReminderTimer = -1;
    }
  }
  private clearHardReminder(): void {
    this.cancelHardReminderTimer();
    this.showHardReminder = false;
    if (this.reminderAction === ReminderAction.HARD) {
      this.reminderAction = ReminderAction.NONE;
      this.reminderAlertType = PostureAlertType.NONE;
      this.reminderMessage = '';
      this.reminderText = '无提醒';
    }
  }
  private scheduleHardReminderDismiss(): void {
    this.cancelHardReminderTimer();
    this.hardReminderTimer = setTimeout(() => {
      this.clearHardReminder();
    }, HARD_REMINDER_TIMEOUT_MS);
  }
  private notifyReminder(action: ReminderAction): void {
    ReminderFeedbackService.notify(action, this.settings.vibration, this.settings.gentleSound);
  }
  private stopReminderFeedback(): void {
    ReminderFeedbackService.stop();
  }
  private reminderCopy(action: ReminderAction, type: PostureAlertType): string {
    const copy = alertTypeSubtitle(type);
    if (action === ReminderAction.HARD) {
      return copy + '，现在调整一下。';
    }
    return copy;
  }
  private todayStats(): TodayStats {
    return computeTodayStats(this.records, this.settings.profile.sampleIntervalMs);
  }
  private alertBreakdown(): AlertBreakdownItem[] {
    return buildAlertBreakdown(this.records);
  }
  private alertBreakdownColor(type: PostureAlertType): string {
    if (type === PostureAlertType.ITEM_02 || type === PostureAlertType.ITEM_01 ||
      type === PostureAlertType.ITEM_07) {
      return RED;
    }
    if (type === PostureAlertType.ITEM_03 || type === PostureAlertType.ITEM_05 ||
      type === PostureAlertType.ITEM_10) {
      return YELLOW;
    }
    if (type === PostureAlertType.ITEM_11) {
      return BLUE;
    }
    return GREEN;
  }
  private alertPercentText(item: AlertBreakdownItem): string {
    if (item.percent === 0 && item.count > 0) {
      return '<1%';
    }
    return item.percent.toString() + '%';
  }
  private recentBuckets(): HourBucket[] {
    return buildRecentBuckets(this.records);
  }
  private recentRecords(): SessionRecord[] {
    return this.records.slice(0, 6);
  }
  private recentRecordLabel(record: SessionRecord): string {
    const type = record.alertType ? record.alertType : PostureAlertType.NONE;
    if (record.action !== ReminderAction.NONE) {
      return actionLabel(record.action, type);
    }
    if (type !== PostureAlertType.NONE) {
      return '识别 · ' + alertTypeLabel(type);
    }
    return '无问题';
  }
  private recentRecordColor(record: SessionRecord): string {
    const type = record.alertType ? record.alertType : PostureAlertType.NONE;
    if (record.action !== ReminderAction.NONE) {
      return reminderColor(record.action);
    }
    if (type !== PostureAlertType.NONE) {
      return this.alertBreakdownColor(type);
    }
    return GREEN;
  }
  private recentLevelSummary(record: SessionRecord): string {
    return levelText(record.sitLevel) + '/' + levelText(record.chinLevel) + '/' + levelText(record.mouthLevel);
  }
  private formatClock(timestamp: number): string {
    const date = new Date(timestamp);
    return date.getHours().toString().padStart(2, '0') + ':' +
      date.getMinutes().toString().padStart(2, '0') + ':' +
      date.getSeconds().toString().padStart(2, '0');
  }
  private formatDegree(value: number): string {
    if (!Number.isFinite(value)) {
      return '0.0°';
    }
    return (Math.round(value * 10) / 10).toFixed(1) + '°';
  }
  private formatBaselineWidth(value: number): string {
    if (!Number.isFinite(value)) {
      return '0';
    }
    return Math.round(value).toString();
  }
  private formatCalibrationStatus(timestamp: number): string {
    if (!Number.isFinite(timestamp) || timestamp <= 0) {
      return '未记录个人基线';
    }
    const date = new Date(timestamp);
    const month = (date.getMonth() + 1).toString().padStart(2, '0');
    const day = date.getDate().toString().padStart(2, '0');
    const time = date.getHours().toString().padStart(2, '0') + ':' +
      date.getMinutes().toString().padStart(2, '0');
    return '已记录个人基线 · ' + month + '/' + day + ' ' + time;
  }
  private sleep(ms: number): Promise<void> {
    return new Promise<void>((resolve: () => void) => {
      setTimeout(resolve, ms);
    });
  }
  private intervalLabel(ms: number): string {
    if (ms === 2000) {
      return '2 秒';
    }
    if (ms === 5000) {
      return '5 秒';
    }
    return '3 秒';
  }
  private sensitivityLabel(value: number): string {
    if (value > 1.05) {
      return '灵敏';
    }
    return '标准';
  }
  build() {
    if (!this.loaded) {
      this.LoadingView()
    } else {
      Stack() {
        Column() {
          this.PageBody()
          this.TabBar()
        }
        .width('100%')
        .height('100%')
        if (this.showHardReminder) {
          this.HardReminderOverlay()
        }
        if (this.showClearDataConfirm) {
          this.ClearDataConfirmOverlay()
        }
        if (this.showResetCalibrationConfirm) {
          this.ResetCalibrationConfirmOverlay()
        }
        if (this.showCoreVisionConfirm) {
          this.CoreVisionConfirmOverlay()
        }
      }
      .width('100%')
      .height('100%')
      .backgroundColor(SOFT)
    }
  }
  @Builder
  private LoadingView() {
    Column({ space: 10 }) {
      Text('坐直了')
        .fontSize(32)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
      Text('读取本地记录')
        .fontSize(15)
        .fontColor(MUTED)
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .backgroundColor(SOFT)
  }
  @Builder
  private PageBody() {
    Scroll() {
      Column({ space: 18 }) {
        this.Header()
        if (this.activeTab === 0) {
          this.GuardPage()
        } else if (this.activeTab === 1) {
          this.StatsPage()
        } else if (this.activeTab === 2) {
          this.GuidePage()
        } else {
          this.SettingsPage()
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 18 })
    }
    .width('100%')
    .layoutWeight(1)
  }
  @Builder
  private Header() {
    Row() {
      Column({ space: 4 }) {
        Text('坐直了')
          .fontSize(30)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Text(this.isGuarding ? '前台守护中' : '前台守护待开启')
          .fontSize(13)
          .fontColor(MUTED)
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      if (this.settings.useCoreVision) {
        this.CameraSurfaceHost()
      }
      Text(this.isGuarding ? 'ON' : 'OFF')
        .width(58)
        .height(34)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isGuarding ? '#FFFFFF' : MUTED)
        .textAlign(TextAlign.Center)
        .lineHeight(34)
        .backgroundColor(this.isGuarding ? GREEN : '#E6EBE4')
        .borderRadius(8)
    }
    .width('100%')
  }
  @Builder
  private GuardPage() {
    Column({ space: 14 }) {
      this.ScorePanel()
      this.MetricGrid()
      this.GuardActions()
      this.PrivacyBand()
    }
    .width('100%')
  }
  @Builder
  private ScorePanel() {
    Column({ space: 16 }) {
      Row() {
        Column({ space: 6 }) {
          Text(this.summary)
            .fontSize(24)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
          Text('上次采样 ' + this.lastSampleText + ' · ' + this.intervalLabel(this.settings.profile.sampleIntervalMs) + ' 抽帧')
            .fontSize(13)
            .fontColor(MUTED)
          if (this.summary === '采样失败') {
            Text(this.sourceDetail)
              .fontSize(12)
              .fontColor(RED)
              .lineHeight(18)
              .maxLines(3)
          }
        }
        .alignItems(HorizontalAlign.Start)
        .layoutWeight(1)
        Text(this.score.toString())
          .width(86)
          .height(86)
          .fontSize(38)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .lineHeight(86)
          .backgroundColor(scoreColor(this.score))
          .borderRadius(8)
      }
      .width('100%')
      Column({ space: 8 }) {
        Row() {
          Text('综合评分')
            .fontSize(13)
            .fontColor(MUTED)
          Blank()
          Text(this.reminderText)
            .fontSize(13)
            .fontWeight(FontWeight.Bold)
            .fontColor(reminderColor(this.reminderAction))
        }
        .width('100%')
        Row() {
          Text('')
            .height(10)
            .width(this.score.toString() + '%')
            .backgroundColor(scoreColor(this.score))
            .borderRadius(5)
        }
        .width('100%')
        .height(10)
        .backgroundColor('#E4EAE2')
        .borderRadius(5)
      }
      .width('100%')
    }
    .width('100%')
    .padding(18)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private HardReminderOverlay() {
    Column() {
      Column({ space: 14 }) {
        this.AlertImageRow(this.reminderAlertType)
        Text(alertTypeTitle(this.reminderAlertType))
          .fontSize(24)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Text(this.reminderMessage.length > 0 ? this.reminderMessage : alertTypeSubtitle(this.reminderAlertType))
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(MUTED)
          .textAlign(TextAlign.Center)
          .lineHeight(22)
          .maxLines(3)
        Button('知道了')
          .height(46)
          .width('100%')
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor(RED)
          .borderRadius(8)
          .onClick(() => {
            this.clearHardReminder();
          })
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(SURFACE)
      .borderRadius(8)
      .shadow({ radius: 18, color: '#33000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#CC171B1A')
    .zIndex(10)
  }
  @Builder
  private AlertImageRow(type: PostureAlertType) {
    Row({ space: 8 }) {
      this.AlertImageBox(this.alertIncorrectResource(type), RED_SOFT)
      Text('→')
        .width(24)
        .fontSize(22)
        .fontWeight(FontWeight.Bold)
        .fontColor('#EF563D')
        .textAlign(TextAlign.Center)
      this.AlertImageBox(this.alertCorrectResource(type), GREEN_SOFT)
    }
    .width('100%')
    .height(128)
  }
  @Builder
  private AlertImageBox(resource: Resource, background: string) {
    Stack() {
      Image(resource)
        .width('92%')
        .height('92%')
        .objectFit(ImageFit.Contain)
    }
    .layoutWeight(1)
    .height(128)
    .backgroundColor(background)
    .borderRadius(8)
  }
  @Builder
  private ClearDataConfirmOverlay() {
    Column() {
      Column({ space: 16 }) {
        Text('清空本机数据？')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Text('会删除统计记录并恢复默认设置。')
          .fontSize(15)
          .fontColor(MUTED)
          .textAlign(TextAlign.Center)
          .lineHeight(22)
          .maxLines(2)
        Row({ space: 10 }) {
          Button('取消')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .backgroundColor('#F9FAF7')
            .borderRadius(8)
            .border({ width: 1, color: LINE })
            .onClick(() => {
              this.dismissClearDataConfirm();
            })
          Button('清空')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(RED)
            .borderRadius(8)
            .onClick(() => {
              this.confirmClearData();
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(SURFACE)
      .borderRadius(8)
      .shadow({ radius: 18, color: '#33000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#CC171B1A')
    .zIndex(11)
  }
  @Builder
  private ResetCalibrationConfirmOverlay() {
    Column() {
      Column({ space: 16 }) {
        Text('恢复默认基线？')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Text('会清除当前个人校准值，后续识别将使用默认基线。')
          .fontSize(15)
          .fontColor(MUTED)
          .textAlign(TextAlign.Center)
          .lineHeight(22)
          .maxLines(2)
        Row({ space: 10 }) {
          Button('取消')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .backgroundColor('#F9FAF7')
            .borderRadius(8)
            .border({ width: 1, color: LINE })
            .onClick(() => {
              this.dismissResetCalibrationConfirm();
            })
          Button('恢复')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(RED)
            .borderRadius(8)
            .onClick(() => {
              this.confirmResetCalibration();
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(SURFACE)
      .borderRadius(8)
      .shadow({ radius: 18, color: '#33000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#CC171B1A')
    .zIndex(11)
  }
  @Builder
  private CoreVisionConfirmOverlay() {
    Column() {
      Column({ space: 16 }) {
        Text('切换检测源？')
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Text('会停止当前守护并重置基线，请切换后重新记录基线。')
          .fontSize(15)
          .fontColor(MUTED)
          .textAlign(TextAlign.Center)
          .lineHeight(22)
          .maxLines(2)
        Row({ space: 10 }) {
          Button('取消')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .backgroundColor('#F9FAF7')
            .borderRadius(8)
            .border({ width: 1, color: LINE })
            .onClick(() => {
              this.dismissCoreVisionConfirm();
            })
          Button('切换')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(RED)
            .borderRadius(8)
            .onClick(() => {
              this.confirmToggleCoreVision();
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(SURFACE)
      .borderRadius(8)
      .shadow({ radius: 18, color: '#33000000', offsetY: 8 })
    }
    .width('100%')
    .height('100%')
    .justifyContent(FlexAlign.Center)
    .alignItems(HorizontalAlign.Center)
    .backgroundColor('#CC171B1A')
    .zIndex(11)
  }
  @Builder
  private MetricGrid() {
    Row({ space: 10 }) {
      this.MetricTile('坐姿', this.sitLevel, this.sitLabel, this.sitValue.toString() + '%')
      this.MetricTile('抬头', this.chinLevel, this.chinLabel, this.chinValue.toString() + '°')
      this.MetricTile('嘴巴', this.mouthLevel, this.mouthLabel, this.mouthValue.toString())
    }
    .width('100%')
  }
  @Builder
  private MetricTile(title: string, level: PostureLevel, label: string, value: string) {
    Column({ space: 6 }) {
      Row() {
        Text(title)
          .fontSize(13)
          .fontColor(MUTED)
        Blank()
        Text(levelText(level))
          .width(48)
          .height(26)
          .fontSize(11)
          .fontWeight(FontWeight.Bold)
          .fontColor(levelColor(level))
          .textAlign(TextAlign.Center)
          .lineHeight(26)
          .backgroundColor(levelSoftColor(level))
          .borderRadius(8)
      }
      .width('100%')
      Text(label)
        .fontSize(15)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .maxLines(1)
      Text(value)
        .fontSize(13)
        .fontColor(MUTED)
    }
    .height(92)
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .padding(12)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private GuardActions() {
    Column({ space: 10 }) {
      Button(this.guardButtonText())
        .height(52)
        .width('100%')
        .fontSize(18)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.isGuarding ? RED : GREEN)
        .borderRadius(8)
        .onClick(() => {
          if (this.isStartingGuard) {
            return;
          }
          if (this.isGuarding) {
            this.stopGuard();
          } else {
            this.startGuard();
          }
        })
      this.PostureInsightCard()
      Row({ space: 10 }) {
        Button('记录基线')
          .height(44)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .backgroundColor(SURFACE)
          .borderRadius(8)
          .border({ width: 1, color: LINE })
          .onClick(() => {
            this.calibrateFromCurrent();
          })
        Button('抽样一次')
          .height(44)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .backgroundColor(SURFACE)
          .borderRadius(8)
          .border({ width: 1, color: LINE })
          .onClick(() => {
            this.sampleOnce();
          })
      }
      .width('100%')
    }
    .width('100%')
  }
  @Builder
  private PostureInsightCard() {
    Row({ space: 14 }) {
      this.PostureDemoFigure()
      Column({ space: 8 }) {
        Row({ space: 8 }) {
          Text('识别')
            .width(42)
            .height(26)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.postureToneColor())
            .textAlign(TextAlign.Center)
            .lineHeight(26)
            .backgroundColor(this.postureSoftColor())
            .borderRadius(8)
          Text(this.postureInsightTitle())
            .fontSize(18)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .maxLines(1)
            .layoutWeight(1)
        }
        .width('100%')
        Text(this.postureInsightAdvice())
          .fontSize(14)
          .fontColor(MUTED)
          .lineHeight(20)
          .maxLines(2)
        Row({ space: 6 }) {
          Text('坐姿')
            .fontSize(12)
            .fontColor(levelColor(this.sitLevel))
            .fontWeight(FontWeight.Bold)
          Text('·')
            .fontSize(12)
            .fontColor(MUTED)
          Text('抬头')
            .fontSize(12)
            .fontColor(levelColor(this.chinLevel))
            .fontWeight(FontWeight.Bold)
          Text('·')
            .fontSize(12)
            .fontColor(MUTED)
          Text('嘴巴')
            .fontSize(12)
            .fontColor(levelColor(this.mouthLevel))
            .fontWeight(FontWeight.Bold)
        }
        .width('100%')
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
    }
    .height(148)
    .width('100%')
    .padding(12)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private PostureDemoFigure() {
    Stack() {
      Image(this.postureInsightResource())
        .width('92%')
        .height('92%')
        .objectFit(ImageFit.Contain)
    }
    .width(116)
    .height(124)
    .backgroundColor(this.postureFigureBackground())
    .borderRadius(8)
  }
  @Builder
  private PrivacyBand() {
    Column({ space: 8 }) {
      Text(this.privacyBandTitle())
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(GREEN)
      Text(this.privacyBandCopy())
        .fontSize(14)
        .fontColor(MUTED)
        .lineHeight(20)
      Text(this.permissionText)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isCameraPermissionGranted ? GREEN : YELLOW)
      Text(this.cameraProbeDisplayText())
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isCameraProbeAvailable ? GREEN : YELLOW)
        .lineHeight(19)
      Text(this.previewSurfaceDisplayText())
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.previewSurfaceDisplayColor())
        .lineHeight(19)
      Text(this.guardWindowText)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isGuarding ? GREEN : MUTED)
        .lineHeight(19)
      Text(this.sourceDisplayText())
        .fontSize(13)
        .fontColor(MUTED)
        .lineHeight(19)
    }
    .width('100%')
    .padding(14)
    .backgroundColor(GREEN_SOFT)
    .borderRadius(8)
    .border({ width: 1, color: '#CFE8D8' })
  }
  @Builder
  private CameraSurfaceHost() {
    XComponent({
      id: 'zuozhile-camera-preview',
      type: XComponentType.SURFACE,
      controller: this.cameraPreviewController
    })
      .width(2)
      .height(2)
      .opacity(0.01)
      .onLoad(() => {
        this.cameraPreviewSurfaceId = this.cameraPreviewController.getXComponentSurfaceId();
        if (!this.isGuarding) {
          this.syncIdleSourceStatus();
        }
      })
      .onDestroy(() => {
        this.cameraPreviewSurfaceId = '';
        if (!this.isGuarding) {
          this.syncIdleSourceStatus();
        }
      })
  }
  private guardButtonText(): string {
    if (this.isStartingGuard) {
      return '启动中';
    }
    return this.isGuarding ? '结束守护' : '开始守护';
  }
  private primaryPostureAlert(): PostureAlertType {
    if (this.sitLevel === PostureLevel.BAD) {
      return this.sitAlertType();
    }
    if (this.chinLevel === PostureLevel.BAD) {
      return this.chinAlertType();
    }
    if (this.mouthLevel === PostureLevel.BAD) {
      return PostureAlertType.ITEM_11;
    }
    if (this.sitLevel === PostureLevel.WARN) {
      return this.sitAlertType();
    }
    if (this.chinLevel === PostureLevel.WARN) {
      return this.chinAlertType();
    }
    if (this.mouthLevel === PostureLevel.WARN) {
      return PostureAlertType.ITEM_11;
    }
    return PostureAlertType.NONE;
  }
  private sitAlertType(): PostureAlertType {
    if (this.sitLabel.indexOf('下滑') >= 0 || this.sitLabel.indexOf('靠前') >= 0 ||
      this.sitLabel.indexOf('椅背') >= 0) {
      return PostureAlertType.ITEM_07;
    }
    if (this.sitLabel.indexOf('含胸') >= 0 || this.sitLabel.indexOf('前扣') >= 0) {
      return PostureAlertType.ITEM_01;
    }
    if (this.sitLabel.indexOf('歪') >= 0 || this.sitLabel.indexOf('不平') >= 0) {
      return this.sitLabel.indexOf('头') >= 0 ? PostureAlertType.ITEM_06 : PostureAlertType.ITEM_02;
    }
    return this.sitLevel === PostureLevel.GOOD ? PostureAlertType.NONE : PostureAlertType.ITEM_01;
  }
  private chinAlertType(): PostureAlertType {
    if (this.chinLabel.indexOf('前探') >= 0 || this.chinLabel.indexOf('下巴') >= 0) {
      return PostureAlertType.ITEM_05;
    }
    return this.chinLevel === PostureLevel.GOOD ? PostureAlertType.NONE : PostureAlertType.ITEM_03;
  }
  private postureInsightTitle(): string {
    const alert = this.primaryPostureAlert();
    if (alert === PostureAlertType.ITEM_01) {
      return '含胸趋势';
    }
    if (alert === PostureAlertType.ITEM_02) {
      return '左右不平';
    }
    if (alert === PostureAlertType.ITEM_03) {
      return '低头趋势';
    }
    if (alert === PostureAlertType.ITEM_05) {
      return '下巴前探';
    }
    if (alert === PostureAlertType.ITEM_06) {
      return '头部偏斜';
    }
    if (alert === PostureAlertType.ITEM_07) {
      return '身体靠近屏幕';
    }
    if (alert === PostureAlertType.ITEM_10) {
      return '屏幕偏低';
    }
    if (alert === PostureAlertType.ITEM_11) {
      return '嘴巴张开';
    }
    if (alert === PostureAlertType.ITEM_12) {
      return '久坐提醒';
    }
    return '坐姿端正';
  }
  private postureInsightAdvice(): string {
    const alert = this.primaryPostureAlert();
    if (alert === PostureAlertType.ITEM_01) {
      return '肩膀向后打开，胸口轻轻向上，背轻轻靠回椅背。';
    }
    if (alert === PostureAlertType.ITEM_02) {
      return '两侧肩膀放平，重心回到椅子中间。';
    }
    if (alert === PostureAlertType.ITEM_03) {
      return '抬高下巴一点，让视线回到屏幕上缘附近。';
    }
    if (alert === PostureAlertType.ITEM_05) {
      return '把下巴轻轻往回收，避免脖子跟着屏幕往前探。';
    }
    if (alert === PostureAlertType.ITEM_06) {
      return '头部回到身体中线，屏幕尽量放在正前方。';
    }
    if (alert === PostureAlertType.ITEM_07) {
      return '身体坐回椅背，手臂可以向前操作，但胸口别跟着贴近屏幕。';
    }
    if (alert === PostureAlertType.ITEM_10) {
      return '把屏幕垫高一点，减少反复低头。';
    }
    if (alert === PostureAlertType.ITEM_11) {
      return '下颌放松，嘴唇自然闭合，鼻呼吸会更稳。';
    }
    if (alert === PostureAlertType.ITEM_12) {
      return '深呼吸几次，顺便检查双脚是否平放在地面。';
    }
    return '保持屏幕略低于视线，肩膀放松，腰背自然伸展。';
  }
  private postureInsightResource(): Resource {
    const alert = this.primaryPostureAlert();
    if (alert === PostureAlertType.NONE) {
      return this.guideCorrectResource(1);
    }
    return this.alertIncorrectResource(alert);
  }
  private postureToneColor(): string {
    const alert = this.primaryPostureAlert();
    if (alert === PostureAlertType.NONE) {
      return GREEN;
    }
    if (this.sitLevel === PostureLevel.BAD || this.chinLevel === PostureLevel.BAD ||
      this.mouthLevel === PostureLevel.BAD) {
      return RED;
    }
    return YELLOW;
  }
  private postureSoftColor(): string {
    const alert = this.primaryPostureAlert();
    if (alert === PostureAlertType.NONE) {
      return GREEN_SOFT;
    }
    if (this.sitLevel === PostureLevel.BAD || this.chinLevel === PostureLevel.BAD ||
      this.mouthLevel === PostureLevel.BAD) {
      return RED_SOFT;
    }
    return YELLOW_SOFT;
  }
  private postureFigureBackground(): string {
    const alert = this.primaryPostureAlert();
    if (alert === PostureAlertType.NONE) {
      return '#F4FBF6';
    }
    if (this.sitLevel === PostureLevel.BAD || this.chinLevel === PostureLevel.BAD ||
      this.mouthLevel === PostureLevel.BAD) {
      return '#FFF1EE';
    }
    return '#FFF9EA';
  }
  @Builder
  private StatsPage() {
    Column({ space: 14 }) {
      this.TodaySummary()
      this.AlertBreakdownPanel()
      this.HourChart()
      this.RecentList()
    }
    .width('100%')
  }
  @Builder
  private TodaySummary() {
    Column({ space: 12 }) {
      Row() {
        Text('今日')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Blank()
        Text(this.todayStats().sampleCount.toString() + ' 次采样')
          .fontSize(13)
          .fontColor(MUTED)
      }
      .width('100%')
      Row({ space: 10 }) {
        StatTile({ label: '均分', value: this.todayStats().averageScore.toString(), color: scoreColor(this.todayStats().averageScore) })
        StatTile({ label: '端正', value: this.todayStats().uprightMinutes.toString() + '分', color: GREEN })
        StatTile({ label: '提醒', value: this.todayStats().remindCount.toString(), color: RED })
      }
      .width('100%')
      Row({ space: 10 }) {
        SmallCounter({ label: '正常', value: this.todayStats().uprightCount, color: GREEN })
        SmallCounter({ label: '注意', value: this.todayStats().warnCount, color: YELLOW })
        SmallCounter({ label: '纠正', value: this.todayStats().badCount, color: RED })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private AlertBreakdownPanel() {
    Column({ space: 12 }) {
      Row() {
        Text('今日问题')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Blank()
        Text(this.alertBreakdown().length.toString() + ' 类')
          .fontSize(13)
          .fontColor(MUTED)
      }
      .width('100%')
      if (this.alertBreakdown().length === 0) {
        Text('暂无姿势提醒')
          .height(56)
          .fontSize(15)
          .fontColor(MUTED)
          .textAlign(TextAlign.Center)
          .width('100%')
          .lineHeight(56)
          .backgroundColor('#F9FAF7')
          .borderRadius(8)
      } else {
        ForEach(this.alertBreakdown().slice(0, 5), (item: AlertBreakdownItem) => {
          Column({ space: 6 }) {
            Row() {
              Text(alertTypeLabel(item.type))
                .fontSize(14)
                .fontWeight(FontWeight.Bold)
                .fontColor(INK)
              Blank()
              Text(item.count.toString() + '次 · ' + this.alertPercentText(item))
                .fontSize(12)
                .fontColor(MUTED)
            }
            .width('100%')
            Row() {
              Text('')
                .height(8)
                .width(Math.max(8, item.percent).toString() + '%')
                .backgroundColor(this.alertBreakdownColor(item.type))
                .borderRadius(4)
            }
            .width('100%')
            .height(8)
            .backgroundColor('#EDF2EA')
            .borderRadius(4)
          }
          .width('100%')
          .padding({ left: 10, right: 10, top: 10, bottom: 10 })
          .backgroundColor('#F9FAF7')
          .borderRadius(8)
        }, (item: AlertBreakdownItem) => item.type)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private HourChart() {
    Column({ space: 12 }) {
      Text('最近时段')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
      Row({ space: 8 }) {
        ForEach(this.recentBuckets(), (bucket: HourBucket) => {
          Column({ space: 6 }) {
            Stack({ alignContent: Alignment.Bottom }) {
              Text('')
                .width('100%')
                .height(112)
                .backgroundColor('#EDF2EA')
                .borderRadius(8)
              Text('')
                .width('100%')
                .height(Math.max(8, bucket.score))
                .backgroundColor(scoreColor(bucket.score))
                .borderRadius(8)
            }
            .height(112)
            .width('100%')
            Text(bucket.label)
              .fontSize(10)
              .fontColor(MUTED)
              .maxLines(1)
            Text(bucket.badRate.toString() + '%')
              .fontSize(10)
              .fontColor(bucket.badRate > 25 ? RED : MUTED)
          }
          .layoutWeight(1)
        }, (bucket: HourBucket) => bucket.label)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private RecentList() {
    Column({ space: 10 }) {
      Text('最近记录')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
      if (this.records.length === 0) {
        Text('暂无记录')
          .height(56)
          .fontSize(15)
          .fontColor(MUTED)
          .textAlign(TextAlign.Center)
          .width('100%')
          .lineHeight(56)
          .backgroundColor('#F9FAF7')
          .borderRadius(8)
      } else {
        ForEach(this.recentRecords(), (record: SessionRecord) => {
          Row() {
            Text(this.formatClock(record.timestamp))
              .width(68)
              .fontSize(13)
              .fontColor(MUTED)
            Text(record.score.toString())
              .width(44)
              .fontSize(18)
              .fontWeight(FontWeight.Bold)
              .fontColor(scoreColor(record.score))
            Text(this.recentLevelSummary(record))
              .fontSize(12)
              .fontColor(INK)
              .layoutWeight(1)
              .maxLines(1)
            Text(this.recentRecordLabel(record))
              .fontSize(12)
              .fontColor(this.recentRecordColor(record))
          }
          .height(44)
          .width('100%')
          .padding({ left: 10, right: 10 })
          .backgroundColor('#F9FAF7')
          .borderRadius(8)
        }, (record: SessionRecord) => record.timestamp.toString())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  private alertGuideId(type: PostureAlertType): number {
    if (type === PostureAlertType.ITEM_01 || type === PostureAlertType.KYPHOSIS) {
      return 1;
    }
    if (type === PostureAlertType.ITEM_02 || type === PostureAlertType.SHOULDER_TILT) {
      return 2;
    }
    if (type === PostureAlertType.ITEM_03 || type === PostureAlertType.HEAD_DROP) {
      return 3;
    }
    if (type === PostureAlertType.ITEM_05) {
      return 5;
    }
    if (type === PostureAlertType.ITEM_06) {
      return 6;
    }
    if (type === PostureAlertType.ITEM_07 || type === PostureAlertType.BODY_SLIDE) {
      return 7;
    }
    if (type === PostureAlertType.ITEM_10) {
      return 10;
    }
    if (type === PostureAlertType.ITEM_11 || type === PostureAlertType.MOUTH_OPEN) {
      return 11;
    }
    if (type === PostureAlertType.ITEM_12) {
      return 12;
    }
    return 1;
  }
  private alertIncorrectResource(type: PostureAlertType): Resource {
    return this.guideIncorrectResource(this.alertGuideId(type));
  }
  private alertCorrectResource(type: PostureAlertType): Resource {
    return this.guideCorrectResource(this.alertGuideId(type));
  }
  private guideIncorrectResource(id: number): Resource {
    if (id === 1) {
      return $rawfile('assets/posture/01_posture_straighten_incorrect.png');
    }
    if (id === 2) {
      return $rawfile('assets/posture/02_body_centering_incorrect.png');
    }
    if (id === 3) {
      return $rawfile('assets/posture/03_head_lift_incorrect.png');
    }
    if (id === 4) {
      return $rawfile('assets/posture/04_shoulder_relax_incorrect.png');
    }
    if (id === 5) {
      return $rawfile('assets/posture/05_chin_tuck_incorrect.png');
    }
    if (id === 6) {
      return $rawfile('assets/posture/06_head_center_incorrect.png');
    }
    if (id === 7) {
      return $rawfile('assets/posture/07_back_support_incorrect.png');
    }
    if (id === 8) {
      return $rawfile('assets/posture/08_feet_flat_incorrect.png');
    }
    if (id === 9) {
      return $rawfile('assets/posture/09_arm_relax_incorrect.png');
    }
    if (id === 10) {
      return $rawfile('assets/posture/10_screen_height_incorrect.png');
    }
    if (id === 11) {
      return $rawfile('assets/posture/11_mouth_close_incorrect.png');
    }
    return $rawfile('assets/posture/12_deep_breath_incorrect.png');
  }
  private guideCorrectResource(id: number): Resource {
    if (id === 1) {
      return $rawfile('assets/posture/01_posture_straighten_correct.png');
    }
    if (id === 2) {
      return $rawfile('assets/posture/02_body_centering_correct.png');
    }
    if (id === 3) {
      return $rawfile('assets/posture/03_head_lift_correct.png');
    }
    if (id === 4) {
      return $rawfile('assets/posture/04_shoulder_relax_correct.png');
    }
    if (id === 5) {
      return $rawfile('assets/posture/05_chin_tuck_correct.png');
    }
    if (id === 6) {
      return $rawfile('assets/posture/06_head_center_correct.png');
    }
    if (id === 7) {
      return $rawfile('assets/posture/07_back_support_correct.png');
    }
    if (id === 8) {
      return $rawfile('assets/posture/08_feet_flat_correct.png');
    }
    if (id === 9) {
      return $rawfile('assets/posture/09_arm_relax_correct.png');
    }
    if (id === 10) {
      return $rawfile('assets/posture/10_screen_height_correct.png');
    }
    if (id === 11) {
      return $rawfile('assets/posture/11_mouth_close_correct.png');
    }
    return $rawfile('assets/posture/12_deep_breath_correct.png');
  }
  @Builder
  private GuidePage() {
    Column({ space: 12 }) {
      Row() {
        Text('坐姿指南')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Blank()
        Text('12 项')
          .fontSize(13)
          .fontColor(MUTED)
      }
      .width('100%')
      ForEach(GUIDE_ITEMS, (item: PostureGuideItem) => {
        this.GuideCard(item)
      }, (item: PostureGuideItem) => item.id.toString())
    }
    .width('100%')
  }
  @Builder
  private GuideCard(item: PostureGuideItem) {
    Column({ space: 12 }) {
      Row() {
        Text(item.id.toString())
          .width(30)
          .height(30)
          .fontSize(16)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .textAlign(TextAlign.Center)
          .lineHeight(30)
          .backgroundColor('#EF563D')
          .borderRadius(15)
        Text(item.title)
          .fontSize(19)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .layoutWeight(1)
          .maxLines(1)
          .textOverflow({ overflow: TextOverflow.Ellipsis })
      }
      .width('100%')
      Text(item.subtitle)
        .fontSize(14)
        .fontColor(MUTED)
        .lineHeight(20)
        .width('100%')
      Row({ space: 10 }) {
        this.GuideImage(this.guideIncorrectResource(item.id), RED_SOFT)
        Text('→')
          .width(28)
          .fontSize(22)
          .fontWeight(FontWeight.Bold)
          .fontColor('#EF563D')
          .textAlign(TextAlign.Center)
        this.GuideImage(this.guideCorrectResource(item.id), GREEN_SOFT)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private GuideImage(resource: Resource, background: string) {
    Stack() {
      Image(resource)
        .width('92%')
        .height('92%')
        .objectFit(ImageFit.Contain)
    }
    .layoutWeight(1)
    .height(146)
    .backgroundColor(background)
    .borderRadius(8)
  }
  @Builder
  private SettingsPage() {
    Column({ space: 14 }) {
      this.CalibrationPanel()
      this.SamplingPanel()
      this.PrivacyPanel()
      Button('清空本机数据')
        .height(48)
        .width('100%')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(RED)
        .backgroundColor(SURFACE)
        .borderRadius(8)
        .border({ width: 1, color: '#F0C9C5' })
        .onClick(() => {
          this.requestClearData();
        })
    }
    .width('100%')
  }
  @Builder
  private CalibrationPanel() {
    Column({ space: 12 }) {
      Text('校准')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
      Row({ space: 8 }) {
        BaselineTile({ label: '颈角', value: this.formatDegree(this.settings.profile.neutralNeckAngle) })
        BaselineTile({ label: '俯仰', value: this.formatDegree(this.settings.profile.neutralPitch) })
        BaselineTile({ label: '肩宽', value: this.formatBaselineWidth(this.settings.profile.neutralShoulderWidth) })
      }
      .width('100%')
      Text(this.formatCalibrationStatus(this.settings.profile.calibratedAt))
        .fontSize(13)
        .fontColor(MUTED)
        .width('100%')
      Row({ space: 10 }) {
        Button('记录基线')
          .height(44)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor(BLUE)
          .borderRadius(8)
          .onClick(() => {
            this.calibrateFromCurrent();
          })
        Button('恢复默认')
          .height(44)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .backgroundColor('#F9FAF7')
          .borderRadius(8)
          .border({ width: 1, color: LINE })
          .onClick(() => {
            this.requestResetCalibration();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private SamplingPanel() {
    Column({ space: 12 }) {
      Text('抽帧与灵敏度')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
      Row({ space: 8 }) {
        this.SegmentButton('标准', STANDARD_SENSITIVITY)
        this.SegmentButton('灵敏', SENSITIVE_SENSITIVITY)
      }
      .width('100%')
      Row({ space: 8 }) {
        this.IntervalButton(2000)
        this.IntervalButton(3000)
        this.IntervalButton(5000)
      }
      .width('100%')
      Text('当前：' + this.sensitivityLabel(this.settings.profile.sensitivity) + ' · ' +
        this.intervalLabel(this.settings.profile.sampleIntervalMs))
        .fontSize(13)
        .fontColor(MUTED)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private SegmentButton(label: string, value: number) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(Math.abs(value - this.settings.profile.sensitivity) < 0.01 ? '#FFFFFF' : INK)
      Blank()
      Text(Math.abs(value - this.settings.profile.sensitivity) < 0.01 ? '已选' : '选择')
        .fontSize(12)
        .fontColor(Math.abs(value - this.settings.profile.sensitivity) < 0.01 ? '#FFFFFF' : MUTED)
    }
      .height(48)
      .layoutWeight(1)
      .padding({ left: 14, right: 14 })
      .backgroundColor(Math.abs(value - this.settings.profile.sensitivity) < 0.01 ? BLUE : '#F9FAF7')
      .borderRadius(8)
      .border({ width: 1, color: Math.abs(value - this.settings.profile.sensitivity) < 0.01 ? BLUE : LINE })
      .onClick(() => {
        this.setSensitivity(value);
      })
  }
  @Builder
  private IntervalButton(value: number) {
    Button(this.intervalLabel(value))
      .height(42)
      .layoutWeight(1)
      .fontSize(14)
      .fontWeight(FontWeight.Bold)
      .fontColor(this.settings.profile.sampleIntervalMs === value ? '#FFFFFF' : INK)
      .backgroundColor(this.settings.profile.sampleIntervalMs === value ? GREEN : '#F9FAF7')
      .borderRadius(8)
      .border({ width: 1, color: this.settings.profile.sampleIntervalMs === value ? GREEN : LINE })
      .onClick(() => {
        this.setIntervalMs(value);
      })
  }
  @Builder
  private PrivacyPanel() {
    Column({ space: 10 }) {
      Text('隐私与提醒')
        .fontSize(20)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .width('100%')
      this.CoreVisionSwitchRow()
      this.PrivacySwitchRow()
      this.SoundSwitchRow()
      this.VibrationSwitchRow()
    }
    .width('100%')
    .padding(16)
    .backgroundColor(SURFACE)
    .borderRadius(8)
    .border({ width: 1, color: LINE })
  }
  @Builder
  private CoreVisionSwitchRow() {
    Row() {
      Text('真实相机检测')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
      Blank()
      Button(this.settings.useCoreVision ? '开' : '关')
        .width(48)
        .height(30)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.settings.useCoreVision ? '#FFFFFF' : MUTED)
        .backgroundColor(this.settings.useCoreVision ? GREEN : '#E6EBE4')
        .borderRadius(8)
        .onClick(() => {
          this.requestToggleCoreVision();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor('#F9FAF7')
    .borderRadius(8)
  }
  @Builder
  private PrivacySwitchRow() {
    Row() {
      Text('本机隐私模式')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
      Blank()
      Button(this.settings.privacyMode ? '开' : '关')
        .width(48)
        .height(30)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.settings.privacyMode ? '#FFFFFF' : MUTED)
        .backgroundColor(this.settings.privacyMode ? GREEN : '#E6EBE4')
        .borderRadius(8)
        .onClick(() => {
          this.togglePrivacy();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor('#F9FAF7')
    .borderRadius(8)
  }
  @Builder
  private SoundSwitchRow() {
    Row() {
      Text('轻提示音')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
      Blank()
      Button(this.settings.gentleSound ? '开' : '关')
        .width(48)
        .height(30)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.settings.gentleSound ? '#FFFFFF' : MUTED)
        .backgroundColor(this.settings.gentleSound ? GREEN : '#E6EBE4')
        .borderRadius(8)
        .onClick(() => {
          this.toggleSound();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor('#F9FAF7')
    .borderRadius(8)
  }
  @Builder
  private VibrationSwitchRow() {
    Row() {
      Text('短振动')
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
      Blank()
      Button(this.settings.vibration ? '开' : '关')
        .width(48)
        .height(30)
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.settings.vibration ? '#FFFFFF' : MUTED)
        .backgroundColor(this.settings.vibration ? GREEN : '#E6EBE4')
        .borderRadius(8)
        .onClick(() => {
          this.toggleVibration();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor('#F9FAF7')
    .borderRadius(8)
  }
  @Builder
  private TabBar() {
    Row({ space: 6 }) {
      ForEach(TABS, (item: TabItem) => {
        Button(item.label)
          .height(52)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.activeTab === item.index ? '#FFFFFF' : MUTED)
          .backgroundColor(this.activeTab === item.index ? INK : '#EEF2EA')
          .borderRadius(8)
          .onClick(() => {
            this.activeTab = item.index;
          })
      }, (item: TabItem) => item.label)
    }
    .width('100%')
    .padding(10)
    .margin({ left: 18, right: 18, bottom: 18 })
    .backgroundColor('#FDFEFB')
    .borderRadius(8)
    .border({ width: 1, color: LINE })
    .shadow({ radius: 12, color: '#1F000000', offsetY: 4 })
  }
}
