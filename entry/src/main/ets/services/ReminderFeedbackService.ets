import { systemSoundManager } from '@kit.AudioKit';
import { vibrator } from '@kit.SensorServiceKit';
import { ReminderAction } from '../models/PostureTypes';

const SOFT_VIBRATION_MS = 80;
const HARD_VIBRATION_MS = 220;

export class ReminderFeedbackService {
  static async notify(action: ReminderAction, vibrationEnabled: boolean, soundEnabled: boolean): Promise<void> {
    if (action === ReminderAction.NONE) {
      return;
    }

    if (soundEnabled) {
      ReminderFeedbackService.playSystemSound();
    }
    if (!vibrationEnabled) {
      return;
    }

    const duration = action === ReminderAction.HARD ? HARD_VIBRATION_MS : SOFT_VIBRATION_MS;
    try {
      await ReminderFeedbackService.stop();
      await vibrator.startVibration({
        type: 'time',
        duration
      }, {
        usage: 'notification'
      });
    } catch (error) {
    }
  }

  private static async playSystemSound(): Promise<void> {
    let player: systemSoundManager.SystemSoundPlayer | null = null;
    try {
      player = await systemSoundManager.createSystemSoundPlayer();
      if (!player) {
        return;
      }
      await player.load(systemSoundManager.SystemSoundType.PHOTO_SHUTTER);
      await player.play(systemSoundManager.SystemSoundType.PHOTO_SHUTTER);
    } catch (error) {
    } finally {
      if (player) {
        try {
          await player.release();
        } catch (error) {
        }
      }
    }
  }

  static async stop(): Promise<void> {
    try {
      await vibrator.stopVibration();
    } catch (error) {
    }
  }
}
