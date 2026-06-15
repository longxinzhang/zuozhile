import { abilityAccessCtrl, common, Permissions } from '@kit.AbilityKit';
import { buildCalibrationProfile, inspectCalibrationSamples } from '../models/PostureCalibration';
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
  APP_BG,
  BORDER_GLASS,
  CORAL,
  GLASS,
  GLASS_GREEN,
  GLASS_SOFT,
  GREEN,
  GREEN_DEEP,
  GREEN_SOFT,
  INK,
  LINE_SOFT,
  MUTED,
  RED,
  RED_SOFT,
  SHADOW_BLUE,
  SHADOW_CARD,
  SHADOW_CORAL,
  SHADOW_GREEN,
  YELLOW,
  YELLOW_SOFT,
  levelColor,
  BLUE_SOFT,
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

interface DebugSubTabItem {
  index: number;
  label: string;
}

interface DebugCalibrationStepItem {
  index: number;
  title: string;
  instruction: string;
  expected: string;
  guideId: number;
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
  { index: 3, label: '调试' },
  { index: 4, label: '设置' }
];
const DEBUG_TABS: DebugSubTabItem[] = [
  { index: 0, label: '检测日志' },
  { index: 1, label: '精度校准' },
  { index: 2, label: '参数' }
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
const DEBUG_CALIBRATION_STEPS: DebugCalibrationStepItem[] = [
  { index: 1, title: '正确坐姿', instruction: '坐正，挺胸抬头，目视前方', expected: '不应触发提醒', guideId: 1 },
  { index: 2, title: '低头', instruction: '低头，像平时看手机那样', expected: '抬头', guideId: 3 },
  { index: 3, title: '下巴前探', instruction: '脖子往前探，下巴伸出去', expected: '下巴收', guideId: 5 },
  { index: 4, title: '驼背', instruction: '放松肩膀，让背弯下来', expected: '挺起来', guideId: 1 },
  { index: 5, title: '身体前倾', instruction: '上身往前倾，离开椅背', expected: '靠回椅背', guideId: 7 },
  { index: 6, title: '身体歪斜', instruction: '身体往一侧歪一歪', expected: '坐正', guideId: 2 },
  { index: 7, title: '头部偏斜', instruction: '肩膀不动，只把头歪向一边', expected: '头别歪', guideId: 6 }
];
const CAMERA_PERMISSION: Permissions = 'ohos.permission.CAMERA';
const CALIBRATION_FRAME_COUNT = 10;
const CALIBRATION_COUNTDOWN_SECONDS = 3;
const CALIBRATION_COUNTDOWN_DELAY_MS = 1000;
const CALIBRATION_SAMPLE_DELAY_MS = 500;
const HARD_REMINDER_TIMEOUT_MS = 8000;
const DISPLAY_STABLE_FRAMES = 2;
const REPORT_ALERT_PRIORITY: PostureAlertType[] = [
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

@Entry
@Component
struct Index {
  @State private loaded: boolean = false;
  @State private activeTab: number = 0;
  @State private activeDebugTab: number = 0;
  @State private isGuarding: boolean = false;
  @State private isStartingGuard: boolean = false;
  @State private isStoppingGuard: boolean = false;
  @State private isManualOperation: boolean = false;
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
  @State private calibrationProgressText: string = '';
  @State private isCalibrationProgressHealthy: boolean = true;
  @State private calibrationProgressPercent: number = -1;
  @State private lastSampleText: string = '尚未采样';
  @State private sourceLabel: string = '真实相机检测';
  @State private sourceDetail: string = '真实相机待启动';
  @State private permissionText: string = '相机权限待授权';
  @State private isCameraPermissionGranted: boolean = false;
  @State private cameraProbeText: string = '相机能力待检测';
  @State private isCameraProbeAvailable: boolean = false;
  @State private cameraPreviewSurfaceId: string = '';
  @State private guardWindowText: string = '守护窗口待开启';
  @State private storageStatusText: string = '本地数据待加载';
  @State private isStorageHealthy: boolean = true;
  @State private sessionReportTitle: string = '';
  @State private sessionReportMeta: string = '';
  @State private sessionReportSummary: string = '';
  @State private sessionReportAdvice: string = '';
  @State private sessionReportScore: number = 0;
  @State private debugFeedbackText: string = '';
  private timer: number = -1;
  private hardReminderTimer: number = -1;
  private guardRunId: number = 0;
  private pageRunId: number = 0;
  private storageOperationId: number = 0;
  private guardSessionStartedAt: number = 0;
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
    this.pageRunId += 1;
    if (!this.loaded) {
      this.loadData(this.pageRunId);
    } else if (!this.isGuarding) {
      this.guardWindowText = this.guardWindow.statusDetail();
      this.syncIdleSourceStatus();
    }
  }
  aboutToDisappear(): void {
    this.pageRunId += 1;
    this.stopGuard(false);
  }
  private abilityContext(): common.UIAbilityContext | undefined {
    const hostContext = this.getUIContext().getHostContext();
    if (hostContext) {
      return hostContext as common.UIAbilityContext;
    }
    return undefined;
  }
  private async loadData(pageRunId: number): Promise<void> {
    const context = this.abilityContext();
    if (context) {
      const result = await PostureSessionStore.loadWithStatus(context);
      if (!this.isCurrentPageRun(pageRunId)) {
        return;
      }
      this.applyData(result.data);
      this.setStorageStatus(result.isHealthy ? '本地数据已加载' : '本地数据读取失败，已使用默认数据',
        result.isHealthy);
    } else {
      if (!this.isCurrentPageRun(pageRunId)) {
        return;
      }
      this.applyData(createDefaultData());
      this.setStorageStatus('本地存储不可用', false);
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
      this.setStorageStatus('本地存储不可用', false);
      return;
    }
    const data: AppData = {
      settings: this.copySettings(this.settings),
      records: this.records.slice(),
      lastUpdatedAt: Date.now()
    };
    const pageRunId = this.pageRunId;
    const operationId = this.nextStorageOperationId();
    const savedAt = Date.now();
    this.persistDataAsync(context, data, pageRunId, operationId, savedAt);
  }
  private async persistDataAsync(context: common.UIAbilityContext, data: AppData, pageRunId: number,
    operationId: number, savedAt: number): Promise<void> {
    let isSaved = false;
    try {
      isSaved = await PostureSessionStore.save(context, data);
    } catch (error) {
      isSaved = false;
    }
    if (!this.isCurrentPageRun(pageRunId) || operationId !== this.storageOperationId) {
      return;
    }
    this.setStorageStatus(isSaved ? '本地数据已保存 ' + this.formatClock(savedAt) : '本地数据保存失败', isSaved);
  }
  private nextStorageOperationId(): number {
    this.storageOperationId += 1;
    return this.storageOperationId;
  }
  private setStorageStatus(text: string, isHealthy: boolean): void {
    this.storageStatusText = text;
    this.isStorageHealthy = isHealthy;
  }
  private controlsLocked(): boolean {
    return this.isManualOperation || this.isStartingGuard || this.isStoppingGuard;
  }
  private actionOpacity(): number {
    return this.controlsLocked() ? 0.55 : 1;
  }
  private isCurrentPageRun(runId: number): boolean {
    return runId === this.pageRunId;
  }
  private async startGuard(ignoreOperationLock: boolean = false): Promise<void> {
    if (this.isGuarding || (!ignoreOperationLock && this.controlsLocked())) {
      return;
    }
    this.clearSessionReport();
    this.isStartingGuard = true;
    this.guardRunId += 1;
    const runId = this.guardRunId;
    const pageRunId = this.pageRunId;
    let guardWindowEntered = false;
    try {
      const sourceReady = await this.prepareSourceAccess();
      if (!this.isCurrentPageRun(pageRunId) || !sourceReady) {
        return;
      }
      await this.rebuildPostureSource();
      if (!this.isCurrentPageRun(pageRunId) || runId !== this.guardRunId) {
        await this.postureSource.dispose();
        if (this.isCurrentPageRun(pageRunId)) {
          this.syncSourceStatus();
        }
        return;
      }
      const context = this.abilityContext();
      if (context) {
        await this.guardWindow.enter(context);
        guardWindowEntered = true;
        if (this.isCurrentPageRun(pageRunId)) {
          this.guardWindowText = this.guardWindow.statusDetail();
        }
      }
      if (!this.isCurrentPageRun(pageRunId) || runId !== this.guardRunId) {
        if (guardWindowEntered) {
          await this.guardWindow.leave(context);
          if (this.isCurrentPageRun(pageRunId)) {
            this.guardWindowText = this.guardWindow.statusDetail();
          }
        }
        await this.postureSource.dispose();
        if (this.isCurrentPageRun(pageRunId)) {
          this.syncSourceStatus();
        }
        return;
      }
      this.isGuarding = true;
      this.guardSessionStartedAt = Date.now();
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
  private async stopGuard(updateUi: boolean = true, showReport: boolean = false): Promise<void> {
    if (this.isStoppingGuard) {
      return;
    }
    const shouldBuildReport = updateUi && showReport && this.isGuarding && this.guardSessionStartedAt > 0;
    const sessionStartedAt = this.guardSessionStartedAt;
    this.isStoppingGuard = true;
    this.guardRunId += 1;
    this.isStartingGuard = false;
    try {
      if (this.timer >= 0) {
        clearInterval(this.timer);
        this.timer = -1;
      }
      this.isGuarding = false;
      this.guardSessionStartedAt = 0;
      this.resetDisplayStability();
      if (updateUi) {
        this.resetReminderState('守护已暂停');
        if (shouldBuildReport) {
          this.buildSessionReport(sessionStartedAt, Date.now());
        }
      } else {
        this.cancelHardReminderTimer();
        this.stopReminderFeedback();
        this.showHardReminder = false;
        this.reminderAction = ReminderAction.NONE;
        this.reminderAlertType = PostureAlertType.NONE;
        this.reminderMessage = '';
      }
      await this.postureSource.dispose();
      this.isSampling = false;
      await this.guardWindow.leave(this.abilityContext());
      if (updateUi) {
        this.guardWindowText = this.guardWindow.statusDetail();
        this.syncSourceStatus();
      }
    } finally {
      this.isStoppingGuard = false;
    }
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
    const pageRunId = this.pageRunId;
    this.isSampling = true;
    try {
      const sample = await this.postureSource.sample(this.settings.profile);
      if (!this.isCurrentPageRun(pageRunId) || (!force && (!this.isGuarding || runId !== this.guardRunId))) {
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
      if (!this.isCurrentPageRun(pageRunId) || (!force && (!this.isGuarding || runId !== this.guardRunId))) {
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
    } else if (this.reminderAction !== ReminderAction.HARD &&
      !result.activeAlerts.includes(this.reminderAlertType)) {
      this.clearReminderDisplay();
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
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    const pageRunId = this.pageRunId;
    this.isManualOperation = true;
    const samples: PostureSample[] = [];
    try {
      if (this.isGuarding) {
        await this.stopGuard();
        if (!this.isCurrentPageRun(pageRunId)) {
          return;
        }
      }
      const sourceReady = await this.prepareSourceAccess();
      if (!this.isCurrentPageRun(pageRunId)) {
        return;
      }
      if (!sourceReady) {
        this.setCalibrationProgress(this.reminderText, false, -1);
        return;
      }

      this.isSampling = true;
      for (let second = CALIBRATION_COUNTDOWN_SECONDS; second > 0; second -= 1) {
        const text = second.toString() + '秒后开始校准，请摆好健康姿势';
        this.summary = text;
        this.reminderText = '准备记录健康坐姿基线';
        this.setCalibrationProgress(text, true, 0);
        await this.sleep(CALIBRATION_COUNTDOWN_DELAY_MS);
        if (!this.isCurrentPageRun(pageRunId)) {
          return;
        }
      }
      await this.rebuildPostureSource();
      if (!this.isCurrentPageRun(pageRunId)) {
        return;
      }
      for (let index = 0; index < CALIBRATION_FRAME_COUNT; index += 1) {
        const text = '开始校准，别乱动哦，' + (index + 1).toString() + '/' + CALIBRATION_FRAME_COUNT.toString();
        const percent = Math.round((index + 1) * 100 / CALIBRATION_FRAME_COUNT);
        this.summary = text;
        this.reminderText = '正在记录健康坐姿基线';
        this.setCalibrationProgress(text, true, percent);
        const sample = await this.postureSource.sample(this.settings.profile);
        if (!this.isCurrentPageRun(pageRunId)) {
          return;
        }
        this.lastSample = sample;
        samples.push(sample);
        if (index < CALIBRATION_FRAME_COUNT - 1) {
          await this.sleep(CALIBRATION_SAMPLE_DELAY_MS);
          if (!this.isCurrentPageRun(pageRunId)) {
            return;
          }
        }
      }
      const next = this.copySettings(this.settings);
      const quality = inspectCalibrationSamples(samples);
      if (!quality.isUsable) {
        this.summary = '校准失败';
        this.reminderText = quality.detail;
        this.setCalibrationProgress(quality.detail, false, 100);
        return;
      }
      next.profile = buildCalibrationProfile(samples, this.settings.profile);
      this.settings = next;
      this.summary = '已记录当前基线';
      this.lastSampleText = this.formatClock(next.profile.calibratedAt);
      this.reminder.reset();
      this.resetDisplayStability();
      this.resetReminderState('暂无提醒');
      this.setCalibrationProgress('校准完成，已记录当前基线', true, 100);
      this.persistData();
    } catch (error) {
      if (!this.isCurrentPageRun(pageRunId)) {
        return;
      }
      this.summary = '校准失败';
      this.reminderText = '请确认人脸和上半身在画面内';
      this.setCalibrationProgress('请确认人脸和上半身在画面内', false, -1);
    } finally {
      if (this.isSampling) {
        await this.postureSource.dispose();
        if (this.isCurrentPageRun(pageRunId)) {
          this.postureSource = this.createPostureSource();
          this.syncSourceStatus();
        }
      }
      this.isSampling = false;
      this.isManualOperation = false;
    }
  }
  private resetCalibration(): void {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
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
    this.setCalibrationProgress('已恢复默认基线', true, -1);
    this.reminder.reset();
    this.resetDisplayStability();
    this.resetReminderState('暂无提醒');
    this.persistData();
  }
  private requestResetCalibration(): void {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    this.showResetCalibrationConfirm = true;
  }
  private dismissResetCalibrationConfirm(): void {
    this.showResetCalibrationConfirm = false;
  }
  private confirmResetCalibration(): void {
    this.resetCalibration();
  }
  private requestToggleCoreVision(): void {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    this.showCoreVisionConfirm = true;
  }
  private dismissCoreVisionConfirm(): void {
    this.showCoreVisionConfirm = false;
  }
  private async confirmToggleCoreVision(): Promise<void> {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    this.showCoreVisionConfirm = false;
    await this.toggleCoreVision();
  }
  private isSensitivitySelected(value: number): boolean {
    return Math.abs(value - this.settings.profile.sensitivity) < 0.01;
  }
  private setSensitivity(value: number): void {
    if (this.controlsLocked() || this.isSampling || this.isSensitivitySelected(value)) {
      return;
    }
    const next = this.copySettings(this.settings);
    next.profile.sensitivity = value;
    this.settings = next;
    this.reminder.reset();
    this.resetDisplayStability();
    this.resetReminderState('已切换为' + this.sensitivityLabel(value));
    this.persistData();
  }
  private async setIntervalMs(value: number): Promise<void> {
    if (this.controlsLocked() || this.isSampling || this.settings.profile.sampleIntervalMs === value) {
      return;
    }
    this.isManualOperation = true;
    try {
      const shouldRestart = this.isGuarding;
      const next = this.copySettings(this.settings);
      next.profile.sampleIntervalMs = value;
      this.settings = next;
      this.persistData();
      if (shouldRestart) {
        await this.stopGuard();
        await this.startGuard(true);
      }
    } finally {
      this.isManualOperation = false;
    }
  }
  private async toggleCoreVision(): Promise<void> {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    this.isManualOperation = true;
    try {
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
    } finally {
      this.isManualOperation = false;
    }
  }
  private togglePrivacy(): void {
    if (this.controlsLocked()) {
      return;
    }
    const next = this.copySettings(this.settings);
    next.privacyMode = !next.privacyMode;
    this.settings = next;
    this.persistData();
  }
  private toggleSound(): void {
    if (this.controlsLocked()) {
      return;
    }
    const next = this.copySettings(this.settings);
    next.gentleSound = !next.gentleSound;
    this.settings = next;
    this.persistData();
  }
  private toggleVibration(): void {
    if (this.controlsLocked()) {
      return;
    }
    const next = this.copySettings(this.settings);
    next.vibration = !next.vibration;
    this.settings = next;
    this.persistData();
  }
  private async clearData(): Promise<void> {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    this.isManualOperation = true;
    this.showClearDataConfirm = false;
    try {
      await this.stopGuard();
      const context = this.abilityContext();
      const operationId = this.nextStorageOperationId();
      let isCleared = false;
      if (context) {
        isCleared = await PostureSessionStore.clear(context);
      }
      const defaults = createDefaultData();
      this.settings = this.copySettings(defaults.settings);
      this.records = [];
      this.clearSessionReport();
      this.reminder.reset();
      this.resetDisplayStability();
      this.score = 92;
      this.summary = '坐姿在线';
      this.resetReminderState('暂无提醒');
      this.lastSampleText = '尚未采样';
      if (operationId === this.storageOperationId) {
        this.setStorageStatus(isCleared ? '本地数据已清空' : '本地数据清空失败', isCleared);
      }
      await this.rebuildPostureSource();
    } finally {
      this.isManualOperation = false;
    }
  }
  private requestClearData(): void {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    this.showClearDataConfirm = true;
  }
  private dismissClearDataConfirm(): void {
    this.showClearDataConfirm = false;
  }
  private async confirmClearData(): Promise<void> {
    await this.clearData();
  }
  private async sampleOnce(): Promise<void> {
    if (this.controlsLocked() || this.isSampling) {
      return;
    }
    const pageRunId = this.pageRunId;
    this.isManualOperation = true;
    if (this.isGuarding) {
      try {
        await this.captureFrame(true);
      } finally {
        this.isManualOperation = false;
      }
      return;
    }
    try {
      const sourceReady = await this.prepareSourceAccess();
      if (!this.isCurrentPageRun(pageRunId) || !sourceReady) {
        return;
      }
      await this.rebuildPostureSource();
      if (!this.isCurrentPageRun(pageRunId)) {
        return;
      }
      await this.captureFrame(true);
      await this.postureSource.dispose();
      if (this.isCurrentPageRun(pageRunId)) {
        this.syncSourceStatus();
      }
    } finally {
      this.isManualOperation = false;
    }
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
  private storageDisplayText(): string {
    if (!this.settings.privacyMode || !this.isStorageHealthy) {
      return this.storageStatusText;
    }
    return '本地数据已就绪';
  }
  private storageDisplayColor(): string {
    return this.isStorageHealthy ? GREEN : RED;
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
    this.clearReminderDisplay();
    this.showHardReminder = false;
  }
  private clearReminderDisplay(): void {
    this.reminderAction = ReminderAction.NONE;
    this.reminderAlertType = PostureAlertType.NONE;
    this.reminderMessage = '';
  }
  private setCalibrationProgress(text: string, isHealthy: boolean = true, percent: number = -1): void {
    this.calibrationProgressText = text;
    this.isCalibrationProgressHealthy = isHealthy;
    if (!Number.isFinite(percent) || percent < 0) {
      this.calibrationProgressPercent = -1;
      return;
    }
    this.calibrationProgressPercent = Math.max(0, Math.min(100, Math.round(percent)));
  }
  private calibrationProgressColor(): string {
    return this.isCalibrationProgressHealthy ? BLUE : RED;
  }
  private calibrationProgressSoftColor(): string {
    return this.isCalibrationProgressHealthy ? '#EAF1FF' : RED_SOFT;
  }
  private calibrationProgressPercentText(): string {
    return this.calibrationProgressPercent.toString() + '%';
  }
  private cancelHardReminderTimer(): void {
    if (this.hardReminderTimer >= 0) {
      clearTimeout(this.hardReminderTimer);
      this.hardReminderTimer = -1;
    }
  }
  private clearHardReminder(): void {
    this.cancelHardReminderTimer();
    this.stopReminderFeedback();
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
  private clearSessionReport(): void {
    this.sessionReportTitle = '';
    this.sessionReportMeta = '';
    this.sessionReportSummary = '';
    this.sessionReportAdvice = '';
    this.sessionReportScore = 0;
  }
  private buildSessionReport(startedAt: number, endedAt: number): void {
    const scoped = this.records.filter((record: SessionRecord) => record.timestamp >= startedAt &&
      record.timestamp <= endedAt);
    const duration = this.sessionDurationText(startedAt, endedAt);
    if (scoped.length === 0) {
      this.sessionReportTitle = '本次守护报告';
      this.sessionReportMeta = duration + ' · 暂无有效采样';
      this.sessionReportSummary = '这次守护时间偏短，还没有形成可参考的姿态趋势。';
      this.sessionReportAdvice = '至少连续守护 2 分钟，再根据报告调整桌椅和屏幕。';
      this.sessionReportScore = 0;
      return;
    }

    let scoreTotal = 0;
    let uprightCount = 0;
    let warnCount = 0;
    let badCount = 0;
    let reminderCount = 0;
    scoped.forEach((record: SessionRecord) => {
      scoreTotal += record.score;
      if (this.recordHasBadMetric(record)) {
        badCount += 1;
      } else if (this.recordHasWarnMetric(record)) {
        warnCount += 1;
      } else {
        uprightCount += 1;
      }
      if (record.action !== ReminderAction.NONE) {
        reminderCount += 1;
      }
    });

    const averageScore = Math.round(scoreTotal / scoped.length);
    const uprightPercent = Math.round(uprightCount * 100 / scoped.length);
    const issue = this.primarySessionIssue(scoped);
    this.sessionReportTitle = '本次守护报告';
    this.sessionReportMeta = duration + ' · ' + averageScore.toString() + '分 · 提醒' +
      reminderCount.toString() + '次';
    this.sessionReportSummary = this.sessionSummaryText(averageScore, uprightPercent, warnCount, badCount, issue);
    this.sessionReportAdvice = this.sessionAdviceText(issue, scoped.length);
    this.sessionReportScore = averageScore;
  }
  private recordHasBadMetric(record: SessionRecord): boolean {
    return record.sitLevel === PostureLevel.BAD || record.chinLevel === PostureLevel.BAD ||
      record.mouthLevel === PostureLevel.BAD;
  }
  private recordHasWarnMetric(record: SessionRecord): boolean {
    return record.sitLevel === PostureLevel.WARN || record.chinLevel === PostureLevel.WARN ||
      record.mouthLevel === PostureLevel.WARN;
  }
  private primarySessionIssue(records: SessionRecord[]): PostureAlertType {
    const counts: number[] = REPORT_ALERT_PRIORITY.map(() => 0);
    records.forEach((record: SessionRecord) => {
      const index = REPORT_ALERT_PRIORITY.indexOf(record.alertType);
      if (index >= 0) {
        counts[index] += 1;
      }
    });

    let bestIndex = -1;
    let bestCount = 0;
    counts.forEach((count: number, index: number) => {
      if (count > bestCount) {
        bestCount = count;
        bestIndex = index;
      }
    });
    return bestIndex >= 0 ? REPORT_ALERT_PRIORITY[bestIndex] : PostureAlertType.NONE;
  }
  private sessionDurationText(startedAt: number, endedAt: number): string {
    const elapsedMs = Math.max(0, endedAt - startedAt);
    if (elapsedMs < 60000) {
      return '少于1分钟';
    }
    const minutes = Math.round(elapsedMs / 60000);
    if (minutes < 60) {
      return minutes.toString() + '分钟';
    }
    const hours = Math.floor(minutes / 60);
    const rest = minutes % 60;
    return hours.toString() + '小时' + (rest > 0 ? rest.toString() + '分钟' : '');
  }
  private sessionSummaryText(averageScore: number, uprightPercent: number, warnCount: number, badCount: number,
    issue: PostureAlertType): string {
    if (issue !== PostureAlertType.NONE) {
      return '端正占比 ' + uprightPercent.toString() + '%，主要问题是' + alertTypeLabel(issue) + '。';
    }
    if (averageScore < 72) {
      return '本次均分偏低，但没有形成稳定单项问题。';
    }
    if (badCount === 0 && warnCount === 0) {
      return '整体稳定，端正占比 ' + uprightPercent.toString() + '%。';
    }
    return '整体还可以，端正占比 ' + uprightPercent.toString() + '%，有少量姿态波动。';
  }
  private sessionAdviceText(issue: PostureAlertType, sampleCount: number): string {
    if (sampleCount < 2) {
      return '守护时间再拉长一点，报告会更稳定。';
    }
    if (issue === PostureAlertType.ITEM_01) {
      return '把键盘鼠标拉近一点，肩膀向后打开，背轻轻靠回椅背。';
    }
    if (issue === PostureAlertType.ITEM_02) {
      return '屏幕放在正前方，双脚踩稳，重心回到椅子中间。';
    }
    if (issue === PostureAlertType.ITEM_03 || issue === PostureAlertType.ITEM_10) {
      return '把屏幕垫高一点，让视线回到屏幕上缘附近。';
    }
    if (issue === PostureAlertType.ITEM_05) {
      return '下巴轻轻往回收，减少脖子跟着屏幕往前探。';
    }
    if (issue === PostureAlertType.ITEM_06) {
      return '头部回到身体中线，避免长期偏向一侧看屏幕。';
    }
    if (issue === PostureAlertType.ITEM_07) {
      return '身体坐回椅背，手可以前伸操作，但胸口别贴近屏幕。';
    }
    if (issue === PostureAlertType.ITEM_11) {
      return '下颌放松、嘴唇自然闭合，保持轻松鼻呼吸。';
    }
    if (issue === PostureAlertType.ITEM_12) {
      return '起身活动 1 分钟，再回来继续工作。';
    }
    return '继续保持屏幕略低于视线，肩膀放松，腰背自然伸展。';
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
  private isSameDayTime(left: number, right: number): boolean {
    const a = new Date(left);
    const b = new Date(right);
    return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
  }
  private debugTodayRecords(): SessionRecord[] {
    const now = Date.now();
    return this.records.filter((record: SessionRecord) => this.isSameDayTime(record.timestamp, now));
  }
  private debugTodayAlertRecords(): SessionRecord[] {
    return this.debugTodayRecords().filter((record: SessionRecord) => record.alertType !== PostureAlertType.NONE);
  }
  private debugRecentDetectionRecords(): SessionRecord[] {
    const alerts = this.records.filter((record: SessionRecord) => record.alertType !== PostureAlertType.NONE);
    if (alerts.length > 0) {
      return alerts.slice(0, 6);
    }
    return this.records.slice(0, 6);
  }
  private debugDetectionCountText(): string {
    return this.debugTodayAlertRecords().length.toString() + ' 条';
  }
  private debugPendingText(): string {
    return this.debugTodayAlertRecords().length.toString();
  }
  private debugAccuracyText(): string {
    return '待标注';
  }
  private debugRecordTitle(record: SessionRecord): string {
    const type = record.alertType ? record.alertType : PostureAlertType.NONE;
    if (type !== PostureAlertType.NONE) {
      return alertTypeLabel(type);
    }
    return '未触发提醒';
  }
  private debugRecordReason(record: SessionRecord): string {
    const type = record.alertType ? record.alertType : PostureAlertType.NONE;
    if (type !== PostureAlertType.NONE) {
      return alertTypeSubtitle(type);
    }
    return '本帧未达到提醒阈值，记录为普通采样。';
  }
  private debugRecordTone(record: SessionRecord): string {
    const type = record.alertType ? record.alertType : PostureAlertType.NONE;
    if (type !== PostureAlertType.NONE) {
      return this.alertBreakdownColor(type);
    }
    return GREEN;
  }
  private markDebugFeedback(record: SessionRecord, isCorrect: boolean): void {
    this.debugFeedbackText = this.formatClock(record.timestamp) + ' · ' +
      this.debugRecordTitle(record) + ' · ' + (isCorrect ? '判定正确' : '提醒有误');
  }
  private debugSampleConfidenceText(): string {
    if (!this.lastSample) {
      return '暂无';
    }
    return Math.round(this.lastSample.face.confidence * 100).toString() + '%';
  }
  private debugPointStatusText(): string {
    if (!this.lastSample) {
      return '暂无关键点';
    }
    const skeleton = this.lastSample.skeleton;
    let count = 0;
    if (skeleton.nose) {
      count += 1;
    }
    if (skeleton.leftShoulder) {
      count += 1;
    }
    if (skeleton.rightShoulder) {
      count += 1;
    }
    if (skeleton.leftHip) {
      count += 1;
    }
    if (skeleton.rightHip) {
      count += 1;
    }
    return count.toString() + '/5 关键点';
  }
  private debugFacePoseText(): string {
    if (!this.lastSample) {
      return '暂无姿态';
    }
    const face = this.lastSample.face;
    return 'pitch ' + this.formatSignedNumber(face.pitch, 1) + '° · roll ' +
      this.formatSignedNumber(face.roll, 1) + '°';
  }
  private debugMouthText(): string {
    if (!this.lastSample) {
      return '暂无';
    }
    return (Math.round(this.lastSample.face.mouthOpenRatio * 100) / 100).toString();
  }
  private debugLastSampleTimeText(): string {
    if (!this.lastSample) {
      return '尚未采样';
    }
    return this.formatClock(this.lastSample.timestamp);
  }
  private formatSignedNumber(value: number, fraction: number): string {
    if (!Number.isFinite(value)) {
      return '0';
    }
    const scaled = Math.round(value * Math.pow(10, fraction)) / Math.pow(10, fraction);
    return scaled > 0 ? '+' + scaled.toFixed(fraction) : scaled.toFixed(fraction);
  }
  private formatDebugNumber(value: number, fraction: number): string {
    if (!Number.isFinite(value)) {
      return '0';
    }
    return (Math.round(value * Math.pow(10, fraction)) / Math.pow(10, fraction)).toFixed(fraction);
  }
  private debugSensitivityScale(): number {
    return Math.max(this.settings.profile.sensitivity, 0.6);
  }
  private debugHigherThreshold(base: number): number {
    return base / this.debugSensitivityScale();
  }
  private debugCompressionThreshold(loss: number): number {
    return 1 - loss / this.debugSensitivityScale();
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
        if (this.settings.useCoreVision) {
          this.CameraSurfaceHost()
        }
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
      .backgroundColor(APP_BG)
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
    .backgroundColor(APP_BG)
  }
  @Builder
  private PageBody() {
    Scroll() {
      Column({ space: 16 }) {
        this.Header()
        if (this.activeTab === 0) {
          this.GuardPage()
        } else if (this.activeTab === 1) {
          this.StatsPage()
        } else if (this.activeTab === 2) {
          this.GuidePage()
        } else if (this.activeTab === 3) {
          this.DebugPage()
        } else {
          this.SettingsPage()
        }
      }
      .width('100%')
      .padding({ left: 18, right: 18, top: 18, bottom: 10 })
    }
    .width('100%')
    .layoutWeight(1)
  }
  @Builder
  private Header() {
    Row() {
      Column({ space: 6 }) {
        Text('坐直了')
          .fontSize(34)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Row({ space: 6 }) {
          Text('')
            .width(8)
            .height(8)
            .backgroundColor(this.isGuarding ? GREEN : MUTED)
            .borderRadius(4)
          Text(this.isGuarding ? '前台守护中' : '前台守护待开启')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.isGuarding ? GREEN_DEEP : MUTED)
        }
      }
      .alignItems(HorizontalAlign.Start)
      .layoutWeight(1)
      Row({ space: 8 }) {
        Text(this.isGuarding ? '守护中' : '未开启')
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.isGuarding ? GREEN_DEEP : MUTED)
        Text('')
          .width(28)
          .height(18)
          .backgroundColor(this.isGuarding ? GREEN : '#DDE6DF')
          .borderRadius(9)
      }
      .height(42)
      .padding({ left: 14, right: 12 })
      .backgroundColor(GLASS)
      .borderRadius(21)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
    Column({ space: 14 }) {
      Row() {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text('')
              .width(18)
              .height(18)
              .backgroundColor(scoreColor(this.score))
              .borderRadius(9)
            Text(this.summary)
              .fontSize(22)
              .fontWeight(FontWeight.Bold)
              .fontColor(INK)
              .maxLines(1)
          }
          Text('上次采样 ' + this.lastSampleText + ' · ' + this.intervalLabel(this.settings.profile.sampleIntervalMs) + ' 抽帧')
            .fontSize(13)
            .fontColor(MUTED)
            .maxLines(1)
          Text('综合评分')
            .fontSize(14)
            .fontWeight(FontWeight.Bold)
            .fontColor(MUTED)
            .margin({ top: 8 })
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
        Stack() {
          Text('')
            .width(106)
            .height(106)
            .backgroundColor(GLASS_GREEN)
            .borderRadius(53)
          Text(this.score.toString())
            .width(106)
            .height(106)
            .fontSize(48)
            .fontWeight(FontWeight.Bold)
            .fontColor(scoreColor(this.score))
            .textAlign(TextAlign.Center)
            .lineHeight(106)
        }
        .width(116)
        .height(116)
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
    .padding(20)
    .backgroundColor(GLASS_GREEN)
    .borderRadius(28)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 30, color: SHADOW_GREEN, offsetY: 12 })
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
          .backgroundColor(CORAL)
          .borderRadius(20)
          .onClick(() => {
            this.clearHardReminder();
          })
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(GLASS)
      .borderRadius(26)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 28, color: '#33000000', offsetY: 10 })
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
    .borderRadius(18)
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
            .backgroundColor(GLASS_SOFT)
            .borderRadius(18)
            .border({ width: 1, color: LINE_SOFT })
            .onClick(() => {
              this.dismissClearDataConfirm();
            })
          Button('清空')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(CORAL)
            .borderRadius(18)
            .onClick(() => {
              this.confirmClearData();
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(GLASS)
      .borderRadius(26)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 28, color: '#33000000', offsetY: 10 })
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
            .backgroundColor(GLASS_SOFT)
            .borderRadius(18)
            .border({ width: 1, color: LINE_SOFT })
            .onClick(() => {
              this.dismissResetCalibrationConfirm();
            })
          Button('恢复')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(CORAL)
            .borderRadius(18)
            .onClick(() => {
              this.confirmResetCalibration();
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(GLASS)
      .borderRadius(26)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 28, color: '#33000000', offsetY: 10 })
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
            .backgroundColor(GLASS_SOFT)
            .borderRadius(18)
            .border({ width: 1, color: LINE_SOFT })
            .onClick(() => {
              this.dismissCoreVisionConfirm();
            })
          Button('切换')
            .height(44)
            .layoutWeight(1)
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(CORAL)
            .borderRadius(18)
            .onClick(() => {
              this.confirmToggleCoreVision();
            })
        }
        .width('100%')
      }
      .width('82%')
      .padding(22)
      .alignItems(HorizontalAlign.Center)
      .backgroundColor(GLASS)
      .borderRadius(26)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 28, color: '#33000000', offsetY: 10 })
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
    Column({ space: 8 }) {
      Row() {
        Text(title)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
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
          .borderRadius(13)
      }
      .width('100%')
      Text(label)
        .fontSize(16)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .maxLines(1)
      Row() {
        Text(value)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(levelColor(level))
        Blank()
        Text('›')
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(MUTED)
      }
      .width('100%')
    }
    .height(126)
    .layoutWeight(1)
    .alignItems(HorizontalAlign.Start)
    .justifyContent(FlexAlign.SpaceBetween)
    .padding(14)
    .backgroundColor(GLASS)
    .borderRadius(22)
    .border({ width: 1, color: LINE_SOFT })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
  }
  @Builder
  private GuardActions() {
    Column({ space: 10 }) {
      Button(this.guardButtonText())
        .height(58)
        .width('100%')
        .fontSize(19)
        .fontWeight(FontWeight.Bold)
        .fontColor('#FFFFFF')
        .backgroundColor(this.guardButtonColor())
        .borderRadius(24)
        .shadow({ radius: 20, color: (this.isGuarding || this.isStoppingGuard) ? SHADOW_CORAL : SHADOW_GREEN, offsetY: 8 })
        .opacity(this.actionOpacity())
        .onClick(() => {
          if (this.controlsLocked()) {
            return;
          }
          if (this.isGuarding) {
            this.stopGuard(true, true);
          } else {
            this.startGuard();
          }
        })
      if (this.sessionReportTitle.length > 0 && !this.isGuarding && !this.isStartingGuard) {
        this.SessionReportCard()
      }
      this.PostureInsightCard()
      Row({ space: 10 }) {
        Button(this.isManualOperation ? '处理中' : '记录基线')
          .height(52)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .backgroundColor(GLASS)
          .borderRadius(22)
          .border({ width: 1, color: BORDER_GLASS })
          .shadow({ radius: 16, color: SHADOW_CARD, offsetY: 6 })
          .opacity(this.actionOpacity())
          .onClick(() => {
            this.calibrateFromCurrent();
          })
        Button(this.isManualOperation ? '处理中' : '抽样一次')
          .height(52)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .backgroundColor(GLASS)
          .borderRadius(22)
          .border({ width: 1, color: BORDER_GLASS })
          .shadow({ radius: 16, color: SHADOW_CARD, offsetY: 6 })
          .opacity(this.actionOpacity())
          .onClick(() => {
            this.sampleOnce();
          })
      }
      .width('100%')
    }
    .width('100%')
  }
  @Builder
  private SessionReportCard() {
    Column({ space: 8 }) {
      Row() {
        Text(this.sessionReportTitle)
          .fontSize(18)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Blank()
        if (this.sessionReportScore > 0) {
          Text(this.sessionReportScore.toString())
            .width(46)
            .height(30)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .lineHeight(30)
            .backgroundColor(scoreColor(this.sessionReportScore))
            .borderRadius(8)
        }
      }
      .width('100%')
      Text(this.sessionReportMeta)
        .fontSize(13)
        .fontColor(MUTED)
        .width('100%')
      Text(this.sessionReportSummary)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(INK)
        .lineHeight(20)
        .maxLines(2)
        .width('100%')
      Row({ space: 8 }) {
        Text('建议')
          .width(42)
          .height(24)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(GREEN)
          .textAlign(TextAlign.Center)
          .lineHeight(24)
          .backgroundColor(GREEN_SOFT)
          .borderRadius(8)
        Text(this.sessionReportAdvice)
          .fontSize(14)
          .fontColor(MUTED)
          .lineHeight(20)
          .maxLines(2)
          .layoutWeight(1)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS)
    .borderRadius(22)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
            .borderRadius(13)
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
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
    .borderRadius(18)
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
      Text(this.storageDisplayText())
        .fontSize(13)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.storageDisplayColor())
        .lineHeight(19)
      Text(this.sourceDisplayText())
        .fontSize(13)
        .fontColor(MUTED)
        .lineHeight(19)
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS_GREEN)
    .borderRadius(22)
    .border({ width: 1, color: '#D9EEDF' })
    .shadow({ radius: 16, color: SHADOW_CARD, offsetY: 6 })
  }
  @Builder
  private CameraSurfaceHost() {
    XComponent({
      id: 'zuozhile-camera-preview',
      type: XComponentType.SURFACE,
      controller: this.cameraPreviewController
    })
      .width(1)
      .height(1)
      .opacity(0)
      .position({ x: -16, y: -16 })
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
    if (this.isManualOperation) {
      return '处理中';
    }
    if (this.isStartingGuard) {
      return '启动中';
    }
    if (this.isStoppingGuard) {
      return '停止中';
    }
    return this.isGuarding ? '结束守护' : '开始守护';
  }
  private guardButtonColor(): string {
    return (this.isGuarding || this.isStoppingGuard) ? CORAL : GREEN;
  }
  private switchTab(index: number): void {
    if (this.controlsLocked()) {
      return;
    }
    this.activeTab = index;
  }
  private primaryPostureAlert(): PostureAlertType {
    if (this.reminderAction !== ReminderAction.NONE && this.reminderAlertType !== PostureAlertType.NONE) {
      return this.reminderAlertType;
    }
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
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
          .backgroundColor(GLASS_SOFT)
          .borderRadius(16)
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
          .backgroundColor(GLASS_SOFT)
          .borderRadius(16)
          .border({ width: 1, color: LINE_SOFT })
        }, (item: AlertBreakdownItem) => item.type)
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
                .backgroundColor('#E7EFE8')
                .borderRadius(14)
              Text('')
                .width('100%')
                .height(Math.max(8, bucket.score))
                .backgroundColor(scoreColor(bucket.score))
                .borderRadius(14)
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
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
          .backgroundColor(GLASS_SOFT)
          .borderRadius(16)
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
          .backgroundColor(GLASS_SOFT)
          .borderRadius(16)
          .border({ width: 1, color: LINE_SOFT })
        }, (record: SessionRecord) => record.timestamp.toString())
      }
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
  }
  @Builder
  private DebugPage() {
    Column({ space: 14 }) {
      Row() {
        Text('检测调试')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Blank()
        Text(this.debugLastSampleTimeText())
          .fontSize(13)
          .fontColor(MUTED)
      }
      .width('100%')
      this.DebugSubTabs()
      if (this.activeDebugTab === 0) {
        this.DebugLogPage()
      } else if (this.activeDebugTab === 1) {
        this.DebugCalibrationPage()
      } else {
        this.DebugParametersPage()
      }
    }
    .width('100%')
  }
  @Builder
  private DebugSubTabs() {
    Row({ space: 8 }) {
      ForEach(DEBUG_TABS, (item: DebugSubTabItem) => {
        Button(item.label)
          .height(42)
          .layoutWeight(1)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.activeDebugTab === item.index ? '#FFFFFF' : INK)
          .backgroundColor(this.activeDebugTab === item.index ? BLUE : GLASS_SOFT)
          .borderRadius(18)
          .border({ width: 1, color: this.activeDebugTab === item.index ? BLUE : LINE_SOFT })
          .onClick(() => {
            this.activeDebugTab = item.index;
          })
      }, (item: DebugSubTabItem) => item.label)
    }
    .width('100%')
  }
  @Builder
  private DebugLogPage() {
    Column({ space: 12 }) {
      this.DebugLogSummary()
      if (this.debugFeedbackText.length > 0) {
        Text('最近标注：' + this.debugFeedbackText)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(BLUE)
          .lineHeight(19)
          .width('100%')
          .padding({ left: 12, right: 12, top: 8, bottom: 8 })
          .backgroundColor(BLUE_SOFT)
          .borderRadius(16)
      }
      if (this.records.length === 0) {
        Text('暂无检测记录。开始守护后，这里会显示最近触发项和采样结果。')
          .fontSize(14)
          .fontColor(MUTED)
          .lineHeight(20)
          .width('100%')
          .padding(14)
          .backgroundColor(GLASS)
          .borderRadius(20)
          .border({ width: 1, color: BORDER_GLASS })
      } else {
        ForEach(this.debugRecentDetectionRecords(), (record: SessionRecord) => {
          this.DebugLogCard(record)
        }, (record: SessionRecord) => record.timestamp.toString())
      }
    }
    .width('100%')
  }
  @Builder
  private DebugLogSummary() {
    Column({ space: 12 }) {
      Row() {
        Text('检测日志')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
        Blank()
        Text('今日 ' + this.debugDetectionCountText())
          .fontSize(13)
          .fontColor(MUTED)
      }
      .width('100%')
      Row({ space: 10 }) {
        StatTile({ label: '准确率', value: this.debugAccuracyText(), color: BLUE })
        StatTile({ label: '待标注', value: this.debugPendingText(), color: YELLOW })
        StatTile({ label: '置信度', value: this.debugSampleConfidenceText(), color: GREEN })
      }
      .width('100%')
      Row({ space: 10 }) {
        SmallCounter({ label: '关键点', value: this.lastSample ? 1 : 0, color: GREEN })
        SmallCounter({ label: '今日采样', value: this.debugTodayRecords().length, color: BLUE })
        SmallCounter({ label: '提醒记录', value: this.debugTodayAlertRecords().length, color: RED })
      }
      .width('100%')
      Text('最近帧：' + this.debugPointStatusText() + ' · ' + this.debugFacePoseText() +
        ' · 嘴部 ' + this.debugMouthText())
        .fontSize(13)
        .fontColor(MUTED)
        .lineHeight(19)
        .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
  }
  @Builder
  private DebugLogCard(record: SessionRecord) {
    Row({ space: 12 }) {
      Stack() {
        Text(record.score.toString())
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
      }
      .width(64)
      .height(64)
      .backgroundColor(scoreColor(record.score))
      .borderRadius(18)
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(this.formatClock(record.timestamp))
            .fontSize(12)
            .fontColor(MUTED)
          Text(this.debugRecordTitle(record))
            .fontSize(15)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .layoutWeight(1)
            .maxLines(1)
        }
        .width('100%')
        Text(this.debugRecordReason(record))
          .fontSize(12)
          .fontColor(MUTED)
          .lineHeight(18)
          .maxLines(2)
          .width('100%')
        Row({ space: 8 }) {
          Text(this.recentLevelSummary(record))
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(this.debugRecordTone(record))
            .layoutWeight(1)
          Button('正确')
            .height(30)
            .width(60)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .backgroundColor(GREEN)
            .borderRadius(15)
            .onClick(() => {
              this.markDebugFeedback(record, true);
            })
          Button('有误')
            .height(30)
            .width(60)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor(RED)
            .backgroundColor('#FFFFFF')
            .borderRadius(15)
            .border({ width: 1, color: '#F0C9C5' })
            .onClick(() => {
              this.markDebugFeedback(record, false);
            })
        }
        .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(GLASS)
    .borderRadius(22)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 14, color: SHADOW_CARD, offsetY: 6 })
  }
  @Builder
  private DebugCalibrationPage() {
    Column({ space: 12 }) {
      Column({ space: 8 }) {
        Text('提高检测精度')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .width('100%')
        Text('这里预留 7 步主动校准流程。当前版本先展示步骤和预期触发项，正式采集会复用真实相机检测链路。')
          .fontSize(14)
          .fontColor(MUTED)
          .lineHeight(20)
          .width('100%')
        Button('先记录健康基线')
          .height(42)
          .width('100%')
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor(BLUE)
          .borderRadius(18)
          .opacity(this.actionOpacity())
          .onClick(() => {
            this.calibrateFromCurrent();
          })
      }
      .width('100%')
      .padding(16)
      .backgroundColor(GLASS)
      .borderRadius(24)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
      ForEach(DEBUG_CALIBRATION_STEPS, (step: DebugCalibrationStepItem) => {
        this.DebugCalibrationStepCard(step)
      }, (step: DebugCalibrationStepItem) => step.index.toString())
    }
    .width('100%')
  }
  @Builder
  private DebugCalibrationStepCard(step: DebugCalibrationStepItem) {
    Row({ space: 12 }) {
      Stack() {
        Image(this.guideIncorrectResource(step.guideId))
          .width('90%')
          .height('90%')
          .objectFit(ImageFit.Contain)
      }
      .width(76)
      .height(76)
      .backgroundColor(RED_SOFT)
      .borderRadius(18)
      Column({ space: 6 }) {
        Row({ space: 8 }) {
          Text(step.index.toString() + '/7')
            .width(42)
            .height(24)
            .fontSize(12)
            .fontWeight(FontWeight.Bold)
            .fontColor('#FFFFFF')
            .textAlign(TextAlign.Center)
            .lineHeight(24)
            .backgroundColor(BLUE)
            .borderRadius(12)
          Text(step.title)
            .fontSize(16)
            .fontWeight(FontWeight.Bold)
            .fontColor(INK)
            .layoutWeight(1)
        }
        .width('100%')
        Text(step.instruction)
          .fontSize(13)
          .fontColor(MUTED)
          .lineHeight(19)
          .width('100%')
        Text('预期触发：' + step.expected)
          .fontSize(12)
          .fontWeight(FontWeight.Bold)
          .fontColor(step.expected === '不应触发提醒' ? GREEN : RED)
          .width('100%')
      }
      .layoutWeight(1)
      .alignItems(HorizontalAlign.Start)
    }
    .width('100%')
    .padding(12)
    .backgroundColor(GLASS)
    .borderRadius(22)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 14, color: SHADOW_CARD, offsetY: 6 })
  }
  @Builder
  private DebugParametersPage() {
    Column({ space: 12 }) {
      Column({ space: 10 }) {
        Text('当前检测参数')
          .fontSize(20)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .width('100%')
        Text('当前档位：' + this.sensitivityLabel(this.settings.profile.sensitivity) + ' · 抽帧 ' +
          this.intervalLabel(this.settings.profile.sampleIntervalMs) + ' · 基线 ' +
          this.formatCalibrationStatus(this.settings.profile.calibratedAt))
          .fontSize(13)
          .fontColor(MUTED)
          .lineHeight(19)
          .width('100%')
      }
      .width('100%')
      .padding(16)
      .backgroundColor(GLASS)
      .borderRadius(24)
      .border({ width: 1, color: BORDER_GLASS })
      .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
      this.DebugParamCard('抬头 pitch 阈值', 'PITCH_HIGH', 15, this.debugHigherThreshold(15), 8, 22, '°')
      this.DebugParamCard('下巴收 鼻肩比', 'NOSE_RATIO_FORWARD', 0.08, this.debugHigherThreshold(0.08), 0.04, 0.15, '')
      this.DebugParamCard('肩宽压缩比', 'SHOULDER_COMPRESSION', 0.88, this.debugCompressionThreshold(0.12), 0.80, 0.94, '')
      this.DebugParamCard('肩膀倾斜', 'SHOULDER_TILT', 0.06, this.debugHigherThreshold(0.06), 0.03, 0.12, '')
      this.DebugParamCard('头部 roll 阈值', 'ROLL_HEAD_ONLY', 10, this.debugHigherThreshold(10), 5, 18, '°')
      this.DebugParamCard('身体靠前脸部倍率', 'FACE_EXPANSION', 1.18,
        1 + 0.18 / this.debugSensitivityScale(), 1.08, 1.35, '')
      this.DebugParamCard('嘴巴张合增量', 'MAR_DELTA', 0.15, this.debugHigherThreshold(0.15), 0.05, 0.35, '')
    }
    .width('100%')
  }
  @Builder
  private DebugParamCard(label: string, key: string, defaultValue: number, currentValue: number, minValue: number,
    maxValue: number, unit: string) {
    Column({ space: 8 }) {
      Row() {
        Text(label)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .layoutWeight(1)
        Text(key)
          .fontSize(11)
          .fontColor(MUTED)
      }
      .width('100%')
      Row() {
        Text('默认: ' + this.formatDebugNumber(defaultValue, unit === '°' ? 1 : 2) + unit)
          .fontSize(12)
          .fontColor(MUTED)
        Blank()
        Text('当前: ' + this.formatDebugNumber(currentValue, unit === '°' ? 1 : 2) + unit)
          .fontSize(13)
          .fontWeight(FontWeight.Bold)
          .fontColor(Math.abs(currentValue - defaultValue) > 0.001 ? YELLOW : INK)
      }
      .width('100%')
      Row() {
        Text('')
          .height(8)
          .width(Math.max(6, Math.min(100, (currentValue - minValue) * 100 / Math.max(maxValue - minValue, 0.01))).toString() + '%')
          .backgroundColor(BLUE)
          .borderRadius(4)
      }
      .width('100%')
      .height(8)
      .backgroundColor('#EDF2EA')
      .borderRadius(4)
      Row() {
        Text(this.formatDebugNumber(minValue, unit === '°' ? 1 : 2) + unit)
          .fontSize(11)
          .fontColor(MUTED)
        Blank()
        Text(this.formatDebugNumber(maxValue, unit === '°' ? 1 : 2) + unit)
          .fontSize(11)
          .fontColor(MUTED)
      }
      .width('100%')
    }
    .width('100%')
    .padding(14)
    .backgroundColor(GLASS)
    .borderRadius(22)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 14, color: SHADOW_CARD, offsetY: 6 })
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
          .backgroundColor(CORAL)
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
          .fontColor(CORAL)
          .textAlign(TextAlign.Center)
        this.GuideImage(this.guideCorrectResource(item.id), GREEN_SOFT)
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 16, color: SHADOW_CARD, offsetY: 7 })
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
    .height(124)
    .backgroundColor(background)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
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
        .fontColor(CORAL)
        .backgroundColor(GLASS)
        .borderRadius(22)
        .border({ width: 1, color: '#F0C9C5' })
        .shadow({ radius: 16, color: SHADOW_CARD, offsetY: 6 })
        .opacity(this.actionOpacity())
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
      if (this.calibrationProgressText.length > 0) {
        Column({ space: 8 }) {
          Row({ space: 8 }) {
            Text(this.calibrationProgressText)
              .fontSize(14)
              .fontWeight(FontWeight.Bold)
              .fontColor(this.calibrationProgressColor())
              .lineHeight(20)
              .maxLines(2)
              .layoutWeight(1)
            if (this.calibrationProgressPercent >= 0) {
              Text(this.calibrationProgressPercentText())
                .width(48)
                .height(24)
                .fontSize(12)
                .fontWeight(FontWeight.Bold)
                .fontColor(this.calibrationProgressColor())
                .textAlign(TextAlign.Center)
                .lineHeight(24)
                .backgroundColor('#FFFFFF')
                .borderRadius(12)
            }
          }
          .width('100%')
          if (this.calibrationProgressPercent >= 0) {
            Row() {
              if (this.calibrationProgressPercent > 0) {
                Text('')
                  .height(8)
                  .width(this.calibrationProgressPercent.toString() + '%')
                  .backgroundColor(this.calibrationProgressColor())
                  .borderRadius(4)
              }
            }
            .width('100%')
            .height(8)
            .backgroundColor('#DDE8F8')
            .borderRadius(4)
          }
        }
          .width('100%')
          .padding({ left: 10, right: 10, top: 8, bottom: 8 })
          .backgroundColor(this.calibrationProgressSoftColor())
          .borderRadius(16)
      }
      Row({ space: 10 }) {
        Button(this.isManualOperation ? '处理中' : '记录基线')
          .height(48)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor('#FFFFFF')
          .backgroundColor(BLUE)
          .borderRadius(20)
          .opacity(this.actionOpacity())
          .onClick(() => {
            this.calibrateFromCurrent();
          })
        Button('恢复默认')
          .height(48)
          .layoutWeight(1)
          .fontSize(15)
          .fontWeight(FontWeight.Bold)
          .fontColor(INK)
          .backgroundColor(GLASS_SOFT)
          .borderRadius(20)
          .border({ width: 1, color: LINE_SOFT })
          .opacity(this.actionOpacity())
          .onClick(() => {
            this.requestResetCalibration();
          })
      }
      .width('100%')
    }
    .width('100%')
    .padding(16)
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
  }
  @Builder
  private SegmentButton(label: string, value: number) {
    Row() {
      Text(label)
        .fontSize(14)
        .fontWeight(FontWeight.Bold)
        .fontColor(this.isSensitivitySelected(value) ? '#FFFFFF' : INK)
      Blank()
      Text(this.isSensitivitySelected(value) ? '已选' : '选择')
        .fontSize(12)
        .fontColor(this.isSensitivitySelected(value) ? '#FFFFFF' : MUTED)
    }
      .height(48)
      .layoutWeight(1)
      .padding({ left: 14, right: 14 })
      .backgroundColor(this.isSensitivitySelected(value) ? BLUE : GLASS_SOFT)
      .borderRadius(20)
      .border({ width: 1, color: this.isSensitivitySelected(value) ? BLUE : LINE_SOFT })
      .opacity(this.actionOpacity())
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
      .backgroundColor(this.settings.profile.sampleIntervalMs === value ? GREEN : GLASS_SOFT)
      .borderRadius(20)
      .border({ width: 1, color: this.settings.profile.sampleIntervalMs === value ? GREEN : LINE_SOFT })
      .opacity(this.actionOpacity())
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
    .backgroundColor(GLASS)
    .borderRadius(24)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 18, color: SHADOW_CARD, offsetY: 8 })
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
        .borderRadius(15)
        .opacity(this.actionOpacity())
        .onClick(() => {
          this.requestToggleCoreVision();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
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
        .borderRadius(15)
        .opacity(this.actionOpacity())
        .onClick(() => {
          this.togglePrivacy();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
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
        .borderRadius(15)
        .opacity(this.actionOpacity())
        .onClick(() => {
          this.toggleSound();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
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
        .borderRadius(15)
        .opacity(this.actionOpacity())
        .onClick(() => {
          this.toggleVibration();
        })
    }
    .height(48)
    .width('100%')
    .padding({ left: 12, right: 10 })
    .backgroundColor(GLASS_SOFT)
    .borderRadius(18)
    .border({ width: 1, color: LINE_SOFT })
  }
  @Builder
  private TabBar() {
    Row({ space: 6 }) {
      ForEach(TABS, (item: TabItem) => {
        Button(item.label)
          .height(56)
          .layoutWeight(1)
          .fontSize(14)
          .fontWeight(FontWeight.Bold)
          .fontColor(this.activeTab === item.index ? GREEN_DEEP : MUTED)
          .backgroundColor(this.activeTab === item.index ? GLASS_GREEN : '#00000000')
          .borderRadius(22)
          .opacity(this.actionOpacity())
          .onClick(() => {
            this.switchTab(item.index);
          })
      }, (item: TabItem) => item.label)
    }
    .width('100%')
    .height(78)
    .padding({ left: 12, right: 12, top: 10, bottom: 10 })
    .margin({ left: 18, right: 18, bottom: 18 })
    .backgroundColor(GLASS)
    .borderRadius(30)
    .border({ width: 1, color: BORDER_GLASS })
    .shadow({ radius: 30, color: SHADOW_BLUE, offsetY: 12 })
  }
}
