import { common } from '@kit.AbilityKit';
import { BusinessError } from '@kit.BasicServicesKit';
import { wearEngine } from '@kit.WearEngine';
import { lowScoreAdvice } from '../models/LowScoreReminder';
import { WearableCandidate, WearableDeviceChoice, WearableStatus, wearableUtf8 } from '../models/WearableReminderPolicy';

export class WearableChannelError extends Error implements Error {
  code: number;
  status: WearableStatus;

  constructor(code: number, status: WearableStatus, message: string) {
    super(message);
    this.code = code;
    this.status = status;
  }
}

export interface WearableNotificationChannel {
  supported(): boolean;
  configured(): boolean;
  discover(current: () => boolean): Promise<WearableDeviceChoice[]>;
  send(routeId: string, candidate: WearableCandidate, current: () => boolean,
    feedback: (action: number, code: number) => void): Promise<void>;
  listen(died: () => void): void;
  close(): Promise<void>;
}

function channelError(code: number): WearableChannelError {
  if (code === 1008500004 || code === 401) {
    return new WearableChannelError(code, WearableStatus.CONFIGURATION, '请核对Wear Engine服务审批、Client ID及签名身份');
  }
  if (code === 1008500002 || code === 1008500003 || code === 1008500010) {
    return new WearableChannelError(code, WearableStatus.DISCONNECTED, '设备已断开或连接标识失效，请刷新并重新选择');
  }
  if (code === 801 || code === 1008500007) {
    return new WearableChannelError(code, WearableStatus.UNSUPPORTED, '设备不支持Wear Engine直发通知');
  }
  if (code === 1008500005 || code === 1008500006 || code === 1008500008 || code === 1008500009) {
    return new WearableChannelError(code, WearableStatus.CONFIGURATION, '请检查华为账号及运动健康隐私准备，不需要健康传感器授权');
  }
  return new WearableChannelError(code, WearableStatus.FAILED,
    code === 1008500001 ? 'Wear Engine网络不可用，未自动重发' : 'Wear Engine调用失败，未自动重发');
}

export class WearEngineNotificationChannel implements WearableNotificationChannel {
  private context: common.UIAbilityContext;
  private deathListener: (() => void) | undefined = undefined;
  private used: boolean = false;
  private closed: boolean = false;

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  supported(): boolean {
    return canIUse('SystemCapability.Health.WearEngine');
  }

  configured(): boolean {
    try {
      const metadata = this.context.currentHapModuleInfo.metadata;
      return metadata !== undefined && metadata.some(item => item.name === 'client_id' &&
        typeof item.value === 'string' && item.value.trim().length > 0);
    } catch (error) {
      return false;
    }
  }

  async discover(current: () => boolean): Promise<WearableDeviceChoice[]> {
    try {
      this.requireActive(current);
      this.used = true;
      const devices = await wearEngine.getDeviceClient(this.context).getConnectedDevices();
      const choices: WearableDeviceChoice[] = [];
      for (const device of devices) {
        this.requireActive(current);
        const supported = await device.isWearEngineCapabilitySupported(wearEngine.WearEngineCapability.NOTIFICATION)
          .catch((error: BusinessError): boolean => {
            if (error.code === 801 || error.code === 1008500007) {
              return false;
            }
            throw channelError(error.code);
          });
        this.requireActive(current);
        if (device.randomId.length === 0) {
          continue;
        }
        const choice = new WearableDeviceChoice();
        choice.routeId = device.randomId;
        choice.name = wearableUtf8(device.name ?? device.model ?? '未命名穿戴设备', 80);
        choice.model = wearableUtf8(device.model ?? '', 80);
        choice.softwareVersion = wearableUtf8(device.softwareVersion ?? '', 60);
        choice.supported = supported;
        choices.push(choice);
      }
      this.requireActive(current);
      return choices;
    } catch (error) {
      if (error instanceof WearableChannelError) {
        throw error;
      }
      const failure: BusinessError = error;
      throw channelError(failure.code ?? 0);
    }
  }

  async send(routeId: string, candidate: WearableCandidate, current: () => boolean,
    feedback: (action: number, code: number) => void): Promise<void> {
    const button: wearEngine.NotificationButton = {
      buttonId: wearEngine.ButtonId.FIRST_BUTTON,
      content: wearableUtf8('知道了', 11)
    };
    const notification: wearEngine.Notification = {
      type: wearEngine.NotificationType.NOTIFICATION_WITH_ONE_BUTTON,
      bundleName: '坐直了',
      title: wearableUtf8(candidate.isTest ? '腕上提醒测试' : '请调整坐姿', 27),
      text: wearableUtf8(candidate.isTest ? '这是一条测试提醒，不计入守护记录。' :
        '当前' + candidate.score.toString() + '分，' + lowScoreAdvice(candidate.adviceCode) + '。', 399),
      buttons: [button]
    };
    const options: wearEngine.NotificationOptions = {
      notification,
      onAction: (result: wearEngine.NotificationFeedback): void => {
        feedback(result.action === undefined ? -1 : result.action, result.errorCode ?? 0);
      }
    };
    try {
      this.requireActive(current);
      this.used = true;
      await wearEngine.getNotifyClient(this.context).notify(routeId, options);
    } catch (error) {
      if (error instanceof WearableChannelError) {
        throw error;
      }
      const failure: BusinessError = error;
      throw channelError(failure.code ?? 0);
    }
  }

  listen(died: () => void): void {
    if (this.deathListener !== undefined) {
      return;
    }
    try {
      this.requireActive((): boolean => true);
      const listener = (): void => {
        if (!this.closed) {
          died();
        }
      };
      wearEngine.on('serviceDie', listener);
      this.deathListener = listener;
      this.used = true;
    } catch (error) {
      if (error instanceof WearableChannelError) {
        throw error;
      }
      const failure: BusinessError = error;
      throw channelError(failure.code ?? 0);
    }
  }

  async close(): Promise<void> {
    this.closed = true;
    const listener = this.deathListener;
    this.deathListener = undefined;
    if (listener !== undefined) {
      try {
        wearEngine.off('serviceDie', listener);
      } catch (error) {
      }
    }
    if (this.used) {
      this.used = false;
      try {
        await wearEngine.destroy();
      } catch (error) {
      }
    }
  }

  private requireActive(current: () => boolean): void {
    if (this.closed || !current()) {
      throw new WearableChannelError(0, WearableStatus.UNKNOWN, '待办已取消，不发送旧通知');
    }
    if (!this.configured()) {
      throw new WearableChannelError(0, WearableStatus.CONFIGURATION, '未配置Client ID，不调用Wear Engine服务');
    }
    if (!this.supported()) {
      throw new WearableChannelError(801, WearableStatus.UNSUPPORTED, '手机不支持Wear Engine能力');
    }
  }
}
