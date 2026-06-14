import { vibrator } from '@kit.SensorServiceKit';
import { ReminderAction } from '../models/PostureTypes';

const SOFT_VIBRATION_MS = 80;
const HARD_VIBRATION_MS = 220;

export class ReminderFeedbackService {
  static async notify(action: ReminderAction, vibrationEnabled: boolean): Promise<void> {
    if (!vibrationEnabled || action === ReminderAction.NONE) {
      return;
    }

    const duration = action === ReminderAction.HARD ? HARD_VIBRATION_MS : SOFT_VIBRATION_MS;
    try {
      await vibrator.startVibration({
        type: 'time',
        duration
      }, {
        usage: 'notification'
      });
    } catch (error) {
    }
  }

  static async stop(): Promise<void> {
    try {
      await vibrator.stopVibration();
    } catch (error) {
    }
  }
}
