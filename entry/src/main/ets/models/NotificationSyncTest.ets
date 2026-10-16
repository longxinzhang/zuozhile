export const NOTIFICATION_SYNC_TEST_ID = 29001;
export const NOTIFICATION_SYNC_TEST_DELAY_MS = 10000;
export const NOTIFICATION_SYNC_TEST_TTL_MS = 5000;
export const NOTIFICATION_SYNC_TEST_COOLDOWN_MS = 60000;

export class NotificationSyncTestState {
  busy: boolean = false;
  scheduled: boolean = false;
  cooldownRemainingMs: number = 0;
  publishedAt: number = 0;
  detail: string = '仅测试手机普通通知与运动健康同步，不调用Wear Engine；腕上显示与振动须实际确认。';
}
