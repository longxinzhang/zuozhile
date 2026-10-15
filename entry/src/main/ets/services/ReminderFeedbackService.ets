import { vibrator } from '@kit.SensorServiceKit';

const PULSE_DURATION_MS = 80;
const PULSE_GAP_MS = 120;

export class ReminderFeedbackService {
  private static generation: number = 0;
  private static available: boolean | undefined = undefined;
  private static availabilityDetail: string = '本地马达尚未检查';
  private static localVibratorId: number = 0;
  private static delayTimer: number = -1;
  private static delayResolve: ((elapsed: boolean) => void) | undefined = undefined;

  static isAvailable(): boolean {
    if (ReminderFeedbackService.available !== undefined) {
      return ReminderFeedbackService.available;
    }
    ReminderFeedbackService.available = false;
    try {
      if (!canIUse('SystemCapability.Sensors.MiscDevice')) {
        ReminderFeedbackService.availabilityDetail = '设备未提供振动系统能力';
        return false;
      }
      const motors: vibrator.VibratorInfo[] = vibrator.getVibratorInfoSync();
      const motor = motors.find((info: vibrator.VibratorInfo): boolean => info.isLocalVibrator);
      if (motor !== undefined) {
        ReminderFeedbackService.localVibratorId = motor.vibratorId;
        ReminderFeedbackService.available = true;
        ReminderFeedbackService.availabilityDetail = '本地马达可用';
      } else {
        ReminderFeedbackService.availabilityDetail = '未查询到本地马达';
      }
    } catch (error) {
      ReminderFeedbackService.availabilityDetail = '本地马达查询失败';
    }
    return ReminderFeedbackService.available === true;
  }

  static statusDetail(): string {
    ReminderFeedbackService.isAvailable();
    return ReminderFeedbackService.availabilityDetail;
  }

  static async pulsePair(isCurrent: () => boolean, onStarted: () => void): Promise<boolean> {
    if (!isCurrent() || !ReminderFeedbackService.isAvailable()) {
      return false;
    }
    const stopping = ReminderFeedbackService.stop();
    const generation = ReminderFeedbackService.generation;
    if (!ReminderFeedbackService.isActive(generation, isCurrent)) {
      return false;
    }
    await stopping;
    if (!ReminderFeedbackService.isActive(generation, isCurrent) || !ReminderFeedbackService.isAvailable()) {
      return false;
    }

    const effect: vibrator.VibrateTime = { type: 'time', duration: PULSE_DURATION_MS };
    const attribute: vibrator.VibrateAttribute = {
      id: ReminderFeedbackService.localVibratorId,
      deviceId: -1,
      usage: 'notification'
    };
    let firstStarted = false;
    try {
      await vibrator.startVibration(effect, attribute);
      firstStarted = true;
    } catch (error) {
      ReminderFeedbackService.available = false;
      ReminderFeedbackService.availabilityDetail = '振动启动失败';
    }
    if (!ReminderFeedbackService.isActive(generation, isCurrent) || !firstStarted) {
      return firstStarted;
    }

    try {
      onStarted();
    } catch (error) {
      return firstStarted;
    }
    if (!ReminderFeedbackService.isActive(generation, isCurrent) || !ReminderFeedbackService.isAvailable()) {
      return firstStarted;
    }

    const elapsed = await new Promise<boolean>((resolve: (elapsed: boolean) => void): void => {
      if (!ReminderFeedbackService.isActive(generation, isCurrent)) {
        resolve(false);
        return;
      }
      ReminderFeedbackService.delayResolve = resolve;
      ReminderFeedbackService.delayTimer = setTimeout((): void => {
        const current = ReminderFeedbackService.isActive(generation, isCurrent);
        if (generation === ReminderFeedbackService.generation) {
          ReminderFeedbackService.delayTimer = -1;
          ReminderFeedbackService.delayResolve = undefined;
        }
        resolve(current);
      }, PULSE_DURATION_MS + PULSE_GAP_MS);
    });
    if (!ReminderFeedbackService.isActive(generation, isCurrent) || !elapsed ||
      !ReminderFeedbackService.isAvailable()) {
      return firstStarted;
    }
    try {
      await vibrator.startVibration(effect, attribute);
    } catch (error) {
      ReminderFeedbackService.available = false;
      ReminderFeedbackService.availabilityDetail = '第二下振动启动失败';
    }
    if (!ReminderFeedbackService.isActive(generation, isCurrent)) {
      return firstStarted;
    }
    return firstStarted;
  }

  private static isActive(generation: number, isCurrent: () => boolean): boolean {
    return generation === ReminderFeedbackService.generation && isCurrent() &&
      generation === ReminderFeedbackService.generation;
  }

  static async stop(): Promise<void> {
    ReminderFeedbackService.generation += 1;
    if (ReminderFeedbackService.delayTimer >= 0) {
      clearTimeout(ReminderFeedbackService.delayTimer);
      ReminderFeedbackService.delayTimer = -1;
    }
    const resolve = ReminderFeedbackService.delayResolve;
    ReminderFeedbackService.delayResolve = undefined;
    if (resolve !== undefined) {
      resolve(false);
    }
    if (!ReminderFeedbackService.isAvailable()) {
      return;
    }
    try {
      await vibrator.stopVibration();
    } catch (error) {
      ReminderFeedbackService.available = false;
      ReminderFeedbackService.availabilityDetail = '振动停止失败';
    }
  }
}
