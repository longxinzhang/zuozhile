import { common } from '@kit.AbilityKit';
import { NotificationSyncTestState } from '../models/NotificationSyncTest';
import { NotificationSyncTestService } from '../services/NotificationSyncTestService';
import { GLASS_SOFT, GREEN_DEEP, GREEN_SOFT, INK, LINE_SOFT, MUTED } from '../theme/ZuozhiTheme';

@Component
export struct NotificationSyncTestPanel {
  @Prop @Watch('availabilityChanged') active: boolean = false;
  @Prop @Watch('availabilityChanged') locked: boolean = false;
  @Prop foreground: boolean = true;
  contextProvider: () => common.UIAbilityContext | undefined = (): common.UIAbilityContext | undefined => undefined;
  testAllowed: () => boolean = (): boolean => false;
  @State private testState: NotificationSyncTestState = new NotificationSyncTestState();
  private service: NotificationSyncTestService = new NotificationSyncTestService();

  aboutToAppear(): void {
    this.service.observe((state: NotificationSyncTestState): void => { this.testState = state; });
  }

  aboutToDisappear(): void {
    this.service.close();
  }

  private availabilityChanged(): void {
    if ((!this.active || this.locked) && this.testState.busy) {
      this.service.cancel();
    }
  }

  private send(delayed: boolean): void {
    if (!this.active || !this.foreground || this.locked || this.testState.busy || !this.testAllowed()) {
      return;
    }
    const context = this.contextProvider();
    if (context === undefined) {
      const state = new NotificationSyncTestState();
      state.detail = '当前无法获取手机通知上下文，请重新打开应用后测试。';
      this.testState = state;
      return;
    }
    this.service.test(context, delayed, (): boolean => this.active && !this.locked && this.testAllowed());
  }

  private canSend(): boolean {
    return this.active && this.foreground && !this.locked && !this.testState.busy &&
      this.testState.cooldownRemainingMs === 0;
  }

  build() {
    Column({ space: 10 }) {
      Text('手机通知同步测试').fontSize(16).fontColor(INK).width('100%')
      Text('此处仅手动测试同步，不会开启自动提醒。需要自动提醒时，请在上方腕上提醒中选择“普通通知同步”并开启。')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      Text('先允许手机系统中的坐直了通知，并在运动健康消息通知中勾选坐直了。测试可能响铃或振动，不启动相机或守护，不写入统计。')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      Button('立即发送一条普通通知').id('notification-sync-test-now').height(42).width('100%').fontSize(13)
        .fontColor(GREEN_DEEP).backgroundColor(GREEN_SOFT).enabled(this.canSend())
        .onClick(() => { this.send(false); })
      Button('10秒后发送，请随后锁屏').id('notification-sync-test-delayed').height(42).width('100%').fontSize(13)
        .fontColor(GREEN_DEEP).backgroundColor(GLASS_SOFT).enabled(this.canSend())
        .onClick(() => { this.send(true); })
      Text(this.testState.detail).id('notification-sync-test-detail')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      if (this.testState.cooldownRemainingMs > 0) {
        Text('普通通知测试独立冷却中，至少间隔60秒；不占用Wear Engine或手机短振动冷却。')
          .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      }
      if (this.testState.scheduled) {
        Button('取消本次等待').id('notification-sync-test-cancel').height(40).width('100%').fontSize(13)
          .fontColor(INK).backgroundColor(GLASS_SOFT).onClick(() => { this.service.cancel(); })
      }
      Button('清除手机测试通知').id('notification-sync-test-clear').height(40).width('100%').fontSize(13)
        .fontColor(MUTED).backgroundColor(GLASS_SOFT)
        .enabled(this.active && this.foreground && !this.locked && !this.testState.busy)
        .onClick(() => { this.service.clear(); })
      Text('手机有通知但手环未提醒：检查连接、佩戴、勿扰/睡眠及“仅熄屏时提醒”等设置。手机发布成功不代表手环已显示或振动。')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
    }.width('100%').padding({ top: 16, bottom: 20 }).border({ width: { bottom: 1 }, color: LINE_SOFT })
  }
}
