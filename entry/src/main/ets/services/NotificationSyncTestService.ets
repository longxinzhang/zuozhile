import { common } from '@kit.AbilityKit';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { backgroundTaskManager } from '@kit.BackgroundTasksKit';
import { notificationManager } from '@kit.NotificationKit';
import { NOTIFICATION_SYNC_TEST_COOLDOWN_MS, NOTIFICATION_SYNC_TEST_DELAY_MS, NOTIFICATION_SYNC_TEST_ID,
  NOTIFICATION_SYNC_TEST_TTL_MS, NotificationSyncTestState } from '../models/NotificationSyncTest';

const TEST_LABEL = 'zuozhile-notification-sync-test';

class NotificationSyncTestError extends Error implements BusinessError {
  code: number = 0;
}

class NotificationSyncWait {
  timer: number = -1;
  cancel: () => void = (): void => {};
}

export class NotificationSyncTestService {
  private static locked: boolean = false;
  private static sdkInFlight: boolean = false;
  private static cooldownUntil: number = 0;
  private static lastUptime: number = 0;
  private static observers: Set<NotificationSyncTestService> = new Set<NotificationSyncTestService>();
  private view: NotificationSyncTestState = new NotificationSyncTestState();
  private generation: number = 0;
  private closed: boolean = false;
  private delayTimer: number = -1;
  private cooldownTimer: number = -1;
  private taskId: number = -1;
  private waits: Set<NotificationSyncWait> = new Set<NotificationSyncWait>();
  private listener: (state: NotificationSyncTestState) => void = (): void => {};

  observe(listener: (state: NotificationSyncTestState) => void): void {
    this.listener = listener;
    NotificationSyncTestService.observers.add(this);
    this.publish();
  }

  state(): NotificationSyncTestState {
    const state = new NotificationSyncTestState();
    state.busy = NotificationSyncTestService.locked || NotificationSyncTestService.sdkInFlight;
    state.scheduled = this.view.scheduled;
    state.cooldownRemainingMs = this.remaining();
    state.publishedAt = this.view.publishedAt;
    state.detail = this.view.detail;
    return state;
  }

  async test(context: common.UIAbilityContext, delayed: boolean, allowed: () => boolean): Promise<void> {
    if (this.closed || this.state().busy || !allowed()) {
      return;
    }
    if (this.remaining() > 0) {
      this.view.detail = '普通通知测试独立冷却60秒，请稍后再试；不会自动发送。';
      this.publish();
      return;
    }
    NotificationSyncTestService.locked = true;
    const generation = ++this.generation;
    const current = (): boolean => !this.closed && generation === this.generation && allowed();
    this.view.detail = '正在检查手机通知权限；测试可能按手机和手环设置响铃或振动。';
    NotificationSyncTestService.notify();
    try {
      let enabled = await this.bounded<boolean>(notificationManager.isNotificationEnabled());
      if (!current()) {
        return;
      }
      if (!enabled) {
        await this.bounded<void>(notificationManager.requestEnableNotification(context), 60000);
        if (!current()) {
          return;
        }
        enabled = await this.bounded<boolean>(notificationManager.isNotificationEnabled());
      }
      if (!current()) {
        return;
      }
      if (!enabled) {
        throw new NotificationSyncTestError('手机通知未开启，请到系统设置 → 通知和状态栏 → 坐直了开启允许通知。');
      }
      await this.bounded<void>(notificationManager.addSlot(notificationManager.SlotType.SERVICE_INFORMATION));
      if (!current()) {
        return;
      }
      let notBefore = this.uptime();
      let deadline = notBefore + NOTIFICATION_SYNC_TEST_TTL_MS;
      if (delayed) {
        if (!canIUse('SystemCapability.ResourceSchedule.BackgroundTaskManager.TransientTask')) {
          throw new NotificationSyncTestError('设备不支持短时后台任务，请使用立即发送；不会安排锁屏后补发。');
        }
        const delayInfo = backgroundTaskManager.requestSuspendDelay('完成用户主动发起的单条通知同步测试', (): void => {
          if (generation === this.generation) {
            this.cancel();
          }
        });
        this.taskId = delayInfo.requestId;
        if (this.taskId < 0 || delayInfo.actualDelayTime <
          NOTIFICATION_SYNC_TEST_DELAY_MS + NOTIFICATION_SYNC_TEST_TTL_MS) {
          throw new NotificationSyncTestError('本次短时后台额度不足，请使用立即发送；未安排通知。');
        }
        notBefore = this.uptime() + NOTIFICATION_SYNC_TEST_DELAY_MS;
        deadline = notBefore + NOTIFICATION_SYNC_TEST_TTL_MS;
        this.view.scheduled = true;
        this.view.detail = '将在10秒后发送一条普通测试通知，请现在锁屏；不要强行关闭应用。';
        this.publish();
        await this.bounded<void>(new Promise<void>((resolve): void => {
          this.delayTimer = setTimeout((): void => { this.delayTimer = -1; resolve(); },
            NOTIFICATION_SYNC_TEST_DELAY_MS);
        }), NOTIFICATION_SYNC_TEST_DELAY_MS + NOTIFICATION_SYNC_TEST_TTL_MS);
      }
      if (!current()) {
        return;
      }
      this.view.scheduled = false;
      enabled = await this.bounded<boolean>(notificationManager.isNotificationEnabled());
      if (!current()) {
        return;
      }
      const uptime = this.uptime();
      if (!Number.isFinite(uptime) || !Number.isFinite(deadline) || uptime < notBefore || uptime >= deadline) {
        throw new NotificationSyncTestError('测试等待已过期，未发送，不会恢复后补发；请重新手动测试。');
      }
      if (!enabled) {
        throw new NotificationSyncTestError('手机通知权限已关闭，未发送；请在系统设置中开启后重试。');
      }
      NotificationSyncTestService.cooldownUntil = uptime + NOTIFICATION_SYNC_TEST_COOLDOWN_MS;
      this.view.publishedAt = 0;
      this.view.detail = '正在发布手机普通通知；这不是Wear Engine请求。';
      this.publish();
      const normal: notificationManager.NotificationBasicContent = {
        title: '坐直了 · 手环同步测试',
        text: '这是一条普通通知测试，请确认手环是否显示、振动。不计入守护记录。',
        additionalText: '运动健康通知同步测试'
      };
      const content: notificationManager.NotificationContent = {
        notificationContentType: notificationManager.ContentType.NOTIFICATION_CONTENT_BASIC_TEXT,
        normal
      };
      const request: notificationManager.NotificationRequest = {
        id: NOTIFICATION_SYNC_TEST_ID,
        label: TEST_LABEL,
        notificationSlotType: notificationManager.SlotType.SERVICE_INFORMATION,
        content
      };
      const sending = notificationManager.publish(request);
      NotificationSyncTestService.sdkInFlight = true;
      sending.then((): void => { NotificationSyncTestService.sdkInFlight = false; NotificationSyncTestService.notify(); },
        (): void => { NotificationSyncTestService.sdkInFlight = false; NotificationSyncTestService.notify(); });
      await this.bounded<void>(sending);
      if (current()) {
        this.view.publishedAt = Date.now();
        this.view.detail = '手机通知发布请求成功。请先确认通知中心有该测试，再检查手环；不代表腕上已收到或振动。';
      }
    } catch (error) {
      if (!this.closed && generation === this.generation) {
        this.view.detail = this.failure(error);
      }
    } finally {
      this.release();
      this.view.scheduled = false;
      NotificationSyncTestService.locked = false;
      NotificationSyncTestService.notify();
    }
  }

  cancel(): void {
    this.generation += 1;
    this.waits.forEach((wait: NotificationSyncWait): void => {
      clearTimeout(wait.timer);
      wait.cancel();
    });
    this.waits.clear();
    this.release();
    this.view.scheduled = false;
    this.view.detail = '未提交的测试已取消；若通知已交系统，不能保证从手机或手环撤回，不自动重发。';
    this.publish();
  }

  async clear(): Promise<void> {
    if (this.closed || this.state().busy) {
      return;
    }
    NotificationSyncTestService.locked = true;
    const generation = this.generation;
    NotificationSyncTestService.notify();
    try {
      const clearing = notificationManager.cancel(NOTIFICATION_SYNC_TEST_ID, TEST_LABEL);
      NotificationSyncTestService.sdkInFlight = true;
      clearing.then((): void => { NotificationSyncTestService.sdkInFlight = false; NotificationSyncTestService.notify(); },
        (): void => { NotificationSyncTestService.sdkInFlight = false; NotificationSyncTestService.notify(); });
      await this.bounded<void>(clearing);
      if (!this.closed && generation === this.generation) {
        this.view.detail = '已清除手机测试通知，不影响其他通知或冷却；手环上的副本请手动清除。';
      }
    } catch (error) {
      if (!this.closed && generation === this.generation) {
        const failure: BusinessError = error;
        this.view.detail = failure.code === 1600007 ? '手机中没有该测试通知；冷却保持不变。' : this.failure(error);
      }
    } finally {
      NotificationSyncTestService.locked = false;
      NotificationSyncTestService.notify();
    }
  }

  close(): void {
    this.closed = true;
    NotificationSyncTestService.observers.delete(this);
    this.cancel();
    if (this.cooldownTimer >= 0) {
      clearTimeout(this.cooldownTimer);
      this.cooldownTimer = -1;
    }
    this.listener = (): void => {};
  }

  private failure(error: BusinessError): string {
    if (error instanceof NotificationSyncTestError) {
      return error.message;
    }
    const failure: BusinessError = error;
    if (failure.code === 1600004 || failure.code === 1600005 || failure.code === 1600020) {
      return '手机通知或服务提醒渠道未开启，请在系统通知设置中检查坐直了；没有自动重试。';
    }
    return '普通通知测试失败' + (typeof failure.code === 'number' ? '（' + failure.code.toString() + '）' : '') +
      '；请检查手机通知设置，没有自动重试。';
  }

  private uptime(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  }

  private remaining(): number {
    try {
      const uptime = this.uptime();
      if (!Number.isFinite(uptime) || uptime < 0) {
        return NOTIFICATION_SYNC_TEST_COOLDOWN_MS;
      }
      if (uptime < NotificationSyncTestService.lastUptime) {
        NotificationSyncTestService.cooldownUntil = uptime + NOTIFICATION_SYNC_TEST_COOLDOWN_MS;
      }
      NotificationSyncTestService.lastUptime = uptime;
      return Math.max(0, NotificationSyncTestService.cooldownUntil - uptime);
    } catch (error) {
      return NOTIFICATION_SYNC_TEST_COOLDOWN_MS;
    }
  }

  private release(): void {
    if (this.delayTimer >= 0) {
      clearTimeout(this.delayTimer);
      this.delayTimer = -1;
    }
    if (this.taskId >= 0) {
      const taskId = this.taskId;
      this.taskId = -1;
      try {
        backgroundTaskManager.cancelSuspendDelay(taskId);
      } catch (error) {
      }
    }
  }

  private bounded<T>(pending: Promise<T>, timeoutMs: number = 5000): Promise<T> {
    const wait = new NotificationSyncWait();
    const started = this.uptime();
    return new Promise<T>((resolve, reject): void => {
      wait.cancel = (): void => { reject(new NotificationSyncTestError('测试已取消，不自动重发。')); };
      wait.timer = setTimeout((): void => {
        this.waits.delete(wait);
        reject(new NotificationSyncTestError('测试操作超时；若已交系统则结果未知，请先检查通知中心，不自动重发。'));
      }, timeoutMs);
      this.waits.add(wait);
      pending.then((value: T): void => {
        clearTimeout(wait.timer);
        this.waits.delete(wait);
        let now = Number.NaN;
        try {
          now = this.uptime();
        } catch (error) {
        }
        if (!Number.isFinite(started) || !Number.isFinite(now) || now < started || now - started >= timeoutMs) {
          reject(new NotificationSyncTestError('测试操作已过期，结果未知，不在恢复后补发。'));
          return;
        }
        resolve(value);
      }, (error: Error): void => {
        clearTimeout(wait.timer);
        this.waits.delete(wait);
        reject(error);
      });
    });
  }

  private publish(): void {
    if (this.closed) {
      return;
    }
    const state = this.state();
    this.listener(state);
    if (state.cooldownRemainingMs > 0 && this.cooldownTimer < 0) {
      this.cooldownTimer = setTimeout((): void => {
        this.cooldownTimer = -1;
        this.publish();
      }, state.cooldownRemainingMs + 1);
    }
  }

  private static notify(): void {
    NotificationSyncTestService.observers.forEach((service: NotificationSyncTestService): void => {
      service.publish();
    });
  }
}
