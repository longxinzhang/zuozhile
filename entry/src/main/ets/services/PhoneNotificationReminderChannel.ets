import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { notificationManager } from '@kit.NotificationKit';
import { lowScoreAdvice } from '../models/LowScoreReminder';
import { WearableCandidate, WearableDeviceChoice, WearableStatus } from '../models/WearableReminderPolicy';
import { WearableChannelError, WearableNotificationChannel } from './WearEngineNotificationChannel';

export const POSTURE_NOTIFICATION_ID = 29002;
export const POSTURE_NOTIFICATION_LABEL = 'zuozhile-posture-reminder';
const NOTIFICATION_FLAG_CLOSE = 2;

export class PhoneNotificationReminderChannel implements WearableNotificationChannel {
  private static authorization: Promise<void> | undefined = undefined;
  private context: common.UIAbilityContext;
  private closed: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  supported(): boolean {
    return canIUse('SystemCapability.Notification.Notification');
  }

  configured(): boolean {
    return !this.closed;
  }

  async prepare(current: () => boolean): Promise<void> {
    try {
      this.requireActive(current);
      if (!await notificationManager.isNotificationEnabled()) {
        this.requireActive(current);
        let authorization = PhoneNotificationReminderChannel.authorization;
        if (authorization === undefined) {
          authorization = notificationManager.requestEnableNotification(this.context);
          PhoneNotificationReminderChannel.authorization = authorization;
          authorization.then((): void => { PhoneNotificationReminderChannel.authorization = undefined; },
            (): void => { PhoneNotificationReminderChannel.authorization = undefined; });
        }
        await authorization;
      }
      this.requireActive(current);
      if (!await notificationManager.isNotificationEnabled()) {
        throw new WearableChannelError(0, WearableStatus.CONFIGURATION,
          '手机通知未开启，请在系统通知设置中允许坐直了通知，再手动准备；未发送通知');
      }
      this.requireActive(current);
      await notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      this.requireActive(current);
      await this.check(current);
    } catch (error) {
      if (error instanceof WearableChannelError) {
        throw error;
      }
      const failure: BusinessError = error;
      throw this.failure(failure.code ?? 0);
    }
  }

  async check(current: () => boolean): Promise<void> {
    try {
      this.requireActive(current);
      const enabled = await notificationManager.isNotificationEnabled();
      this.requireActive(current);
      if (!enabled) {
        throw new WearableChannelError(0, WearableStatus.CONFIGURATION,
          '手机通知权限已关闭；请停止守护后手动准备普通通知，不自动弹权限框或补发');
      }
      const slot = await notificationManager.getSlot(notificationManager.SlotType.SERVICE_INFORMATION);
      this.requireActive(current);
      if (!slot) {
        throw new WearableChannelError(0, WearableStatus.CONFIGURATION,
          '手机服务提醒渠道尚未创建，请停止守护后点击准备手机通知；未发布通知');
      }
      if (slot.enabled === false || slot.notificationLevel === notificationManager.SlotLevel.LEVEL_NONE) {
        throw new WearableChannelError(0, WearableStatus.CONFIGURATION,
          '手机服务提醒渠道已关闭，请在系统通知设置中开启；不会更改你的渠道设置');
      }
    } catch (error) {
      if (error instanceof WearableChannelError) {
        throw error;
      }
      const failure: BusinessError = error;
      throw this.failure(failure.code ?? 0);
    }
  }

  async discover(current: () => boolean): Promise<WearableDeviceChoice[]> {
    await this.check(current);
    return [];
  }

  async send(routeId: string, candidate: WearableCandidate, current: () => boolean,
    feedback: (action: number, code: number) => void): Promise<void> {
    const normal: notificationManager.NotificationBasicContent = {
      title: candidate.isTest ? '坐直了 · 普通通知提醒测试' : '坐直了 · 请调整坐姿',
      text: candidate.isTest ? '这是一条普通通知同步测试，不计入坐姿统计。请确认手环是否显示并振动。' :
        '当前' + candidate.score.toString() + '分，' + lowScoreAdvice(candidate.adviceCode) + '。',
      additionalText: '由运动健康按设置同步'
    };
    const content: notificationManager.NotificationContent = {
      notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
      normal
    };
    const request: notificationManager.NotificationRequest = {
      id: POSTURE_NOTIFICATION_ID,
      label: POSTURE_NOTIFICATION_LABEL,
      notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
      notificationFlags: {
        soundEnabled: NOTIFICATION_FLAG_CLOSE,
        vibrationEnabled: NOTIFICATION_FLAG_CLOSE
      },
      autoDeletedTime: Date.now() + 60000,
      content
    };
    try {
      this.requireActive(current);
      await notificationManager.publish(request);
    } catch (error) {
      if (error instanceof WearableChannelError) {
        throw error;
      }
      const failure: BusinessError = error;
      throw this.failure(failure.code ?? 0);
    }
  }

  listen(died: () => void): void {
  }

  async close(): Promise<void> {
    this.closed = true;
  }

  private requireActive(current: () => boolean): void {
    if (this.closed || !current()) {
      throw new WearableChannelError(0, WearableStatus.UNKNOWN, '待办已取消，不发布旧的手机通知');
    }
    if (!this.supported()) {
      throw new WearableChannelError(801, WearableStatus.UNSUPPORTED, '手机不支持普通通知服务');
    }
  }

  private failure(code: number): WearableChannelError {
    if (code === 801) {
      return new WearableChannelError(code, WearableStatus.UNSUPPORTED, '手机不支持普通通知服务');
    }
    if (code === 1600004 || code === 1600005) {
      return new WearableChannelError(code, WearableStatus.CONFIGURATION,
        '普通通知或服务提醒渠道未就绪，请停止守护后手动准备并检查系统通知设置；不重试或切换通道');
    }
    return new WearableChannelError(code, WearableStatus.FAILED, '手机普通通知调用失败，不自动重试或切换通道');
  }
}
