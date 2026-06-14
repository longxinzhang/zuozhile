import { common } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { BusinessError } from '@ohos.base';

const DOMAIN = 0x0000;
const TAG = 'ZuozhileGuard';
const GUARD_BRIGHTNESS = 0.18;

function errorSummary(error: Error): string {
  let message = error.message;
  if (message === undefined || message.length === 0) {
    message = JSON.stringify(error);
  }
  try {
    const businessError = error as BusinessError;
    return 'code=' + businessError.code.toString() + ' ' + message;
  } catch (ignore) {
    return message;
  }
}

export class GuardWindowService {
  private isActive: boolean = false;
  private previousBrightness: number = -1;
  private detail: string = '守护窗口待开启';

  async enter(context: common.UIAbilityContext): Promise<void> {
    if (this.isActive) {
      return;
    }
    try {
      const currentWindow = await window.getLastWindow(context);
      const properties = currentWindow.getWindowProperties();
      this.previousBrightness = properties.brightness;
      await currentWindow.setWindowKeepScreenOn(true);
      await currentWindow.setWindowBrightness(GUARD_BRIGHTNESS);
      this.isActive = true;
      this.detail = '守护窗口常亮 · 低亮度';
      hilog.info(DOMAIN, TAG, '%{public}s', this.detail);
    } catch (error) {
      this.detail = '守护窗口设置失败：' + errorSummary(error as Error);
      hilog.warn(DOMAIN, TAG, '%{public}s', this.detail);
    }
  }

  async leave(context: common.UIAbilityContext | undefined): Promise<void> {
    if (!context) {
      this.isActive = false;
      this.previousBrightness = -1;
      this.detail = '守护窗口已恢复';
      return;
    }
    try {
      const currentWindow = await window.getLastWindow(context);
      await currentWindow.setWindowKeepScreenOn(false);
      if (this.previousBrightness >= 0) {
        await currentWindow.setWindowBrightness(this.previousBrightness);
      }
      this.detail = '守护窗口已恢复';
      hilog.info(DOMAIN, TAG, '%{public}s', this.detail);
    } catch (error) {
      this.detail = '守护窗口恢复失败：' + errorSummary(error as Error);
      hilog.warn(DOMAIN, TAG, '%{public}s', this.detail);
    } finally {
      this.isActive = false;
      this.previousBrightness = -1;
    }
  }

  statusDetail(): string {
    return this.detail;
  }
}
