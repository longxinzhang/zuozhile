import { WearableDeviceChoice, WearableDiagnostic, WearableTestConfirmation,
  WearableViewState } from '../models/WearableReminderPolicy';
import { WearableReminderRoute } from '../models/PostureTypes';
import { GLASS_SOFT, GREEN, GREEN_DEEP, GREEN_SOFT, INK, LINE_SOFT, MUTED, RED } from '../theme/ZuozhiTheme';

@Component
export struct WearableReminderPanel {
  @Prop reminderEnabled: boolean = false;
  @Prop reminderRoute: WearableReminderRoute = WearableReminderRoute.NOTIFICATION_SYNC;
  @Prop locked: boolean = false;
  @Prop guarding: boolean = false;
  @Prop state: WearableViewState = new WearableViewState();
  onToggle: (enabled: boolean) => void = (): void => {};
  onRoute: (route: WearableReminderRoute) => void = (): void => {};
  onPrepareNotification: () => void = (): void => {};
  onRefresh: () => void = (): void => {};
  onSelect: (routeId: string) => void = (): void => {};
  onTest: () => void = (): void => {};
  onConfirm: (result: WearableTestConfirmation) => void = (): void => {};
  onClear: () => void = (): void => {};
  @State private showAdvancedChannels: boolean = false;
  @State private showTestRecords: boolean = false;

  private testTime(): string {
    return new Date(this.state.testAt).toLocaleString();
  }

  private routeText(route: WearableReminderRoute): string {
    return route === WearableReminderRoute.NOTIFICATION_SYNC ? '普通通知同步' : 'WearEngine（待审批）';
  }

  build() {
    Column({ space: 10 }) {
      Row({ space: 10 }) {
        Column({ space: 4 }) {
          Text('腕上提醒').fontSize(16).fontColor(INK)
          Text(this.state.status).id('wearable-reminder-status').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.reminderEnabled })
          .id('wearable-reminder-toggle').selectedColor(GREEN).enabled(!this.locked)
          .accessibilityText('腕上提醒，默认关闭，仅严重低分')
          .onChange((enabled: boolean) => {
            if (enabled !== this.reminderEnabled) {
              this.onToggle(enabled);
            }
          })
      }.width('100%')
      Text(this.reminderRoute === WearableReminderRoute.NOTIFICATION_SYNC ?
        '通过手机通知同步到手环或手表，在严重低分时提醒。' : '使用Wear Engine通道，在严重低分时提醒。')
        .fontSize(13).fontColor(INK).lineHeight(20).width('100%')
      Text('仅在前台真实守护确认三级且当前低于50分时发送，一、二级不发送。腕上通道共用10秒冷却，与手机60秒短振动独立。')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      Text('开启后，腕上（含锁屏）可能显示分数和建议，并按设备设置振动或响铃；不传输影像、关键点或基线。')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      Text('当前通道 · ' + this.routeText(this.reminderRoute)).id('wearable-reminder-route')
        .fontSize(13).fontColor(this.reminderRoute === WearableReminderRoute.WEAR_ENGINE ? RED : INK).width('100%')
      if (this.reminderRoute === WearableReminderRoute.WEAR_ENGINE) {
        Text('已保留你选择的WearEngine高级通道；该服务待审批，尚未接通。')
          .fontSize(12).fontColor(RED).lineHeight(18).width('100%')
      }
      this.RouteButton(this.reminderRoute === WearableReminderRoute.WEAR_ENGINE ?
        '切回普通通知同步' : '普通通知同步', WearableReminderRoute.NOTIFICATION_SYNC)
      Text('守护停止后可切换通道，只影响新事件，不会补发历史提醒。')
        .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      if (this.reminderRoute === WearableReminderRoute.NOTIFICATION_SYNC) {
        Text('同步配置：允许手机系统中的坐直了通知，在运动健康消息通知中勾选坐直了，并开启“多设备提醒”或允许手机亮屏时提醒。目标设备由运动健康设置决定。')
          .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
        Text('普通通知请求关闭额外手机声音和振动，原短振开关保持独立；手机通知最多保留60秒，腕上副本可能需手动清除。本应用无法检查腕上送达或振动。')
          .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      }
      if (this.reminderEnabled) {
        Text(this.state.detail).id('wearable-reminder-detail')
          .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
        if (this.reminderRoute === WearableReminderRoute.NOTIFICATION_SYNC) {
          Button('准备手机通知权限与渠道').id('wearable-notification-prepare')
            .height(42).width('100%').fontSize(13).fontColor(GREEN_DEEP).backgroundColor(GREEN_SOFT)
            .enabled(!this.locked && !this.guarding && !this.state.busy)
            .onClick(() => { this.onPrepareNotification(); })
          Text('准备只检查或申请手机通知权限，不发送通知；“就绪”仅代表手机侧可发布，腕上显示和振动请分别确认。')
            .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
        }
        Button(this.state.busy ? '腕上通道处理中' :
          this.reminderRoute === WearableReminderRoute.NOTIFICATION_SYNC ?
            '检查手机通知状态' : '刷新WearEngine设备与状态（待审批）')
          .id('wearable-reminder-refresh').height(40).width('100%').fontSize(13)
          .fontColor(GREEN_DEEP).backgroundColor(GREEN_SOFT).enabled(!this.locked && !this.state.busy)
          .onClick(() => { this.onRefresh(); })
      }
      if (!this.state.storageHealthy) {
        Text('腕上本地状态未保存；发送前必须保存冷却，失败时不会向设备提交。')
          .fontSize(12).fontColor(RED).lineHeight(18).width('100%')
      }
      Button(this.showAdvancedChannels ? '高级通道 · 收起' : '高级通道 · 展开')
        .id('wearable-advanced-toggle').height(40).width('100%').fontSize(13)
        .fontColor(MUTED).backgroundColor(GLASS_SOFT)
        .accessibilityText(this.showAdvancedChannels ? '收起高级通道' : '展开高级通道')
        .onClick(() => { this.showAdvancedChannels = !this.showAdvancedChannels; })
      if (this.showAdvancedChannels) {
        Text('WearEngine需要服务审批和有效配置，当前尚未接通。每次只使用所选通道，选择高级通道不会自动启用腕上提醒。')
          .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
        this.RouteButton('WearEngine · 待审批', WearableReminderRoute.WEAR_ENGINE)
        if (this.reminderEnabled && this.reminderRoute === WearableReminderRoute.WEAR_ENGINE) {
          if (this.state.devices.length > 0) {
            Text('明确选择一台目标设备；重连后可能需要重选，不会自动广播。')
              .fontSize(12).fontColor(MUTED).width('100%')
            ForEach(this.state.devices, (device: WearableDeviceChoice, index: number) => {
              this.DeviceRow(device, index)
            }, (device: WearableDeviceChoice) => device.routeId)
          }
          if (this.state.selectedName.length > 0) {
            Text('当前目标：' + this.state.selectedName).fontSize(13).fontColor(INK).width('100%')
          }
        }
      }
      Button(this.showTestRecords ? '测试与记录 · 收起' : '测试与记录 · 展开')
        .id('wearable-records-toggle').height(40).width('100%').fontSize(13)
        .fontColor(MUTED).backgroundColor(GLASS_SOFT)
        .accessibilityText(this.showTestRecords ? '收起测试与记录' : '展开测试与记录')
        .onClick(() => { this.showTestRecords = !this.showTestRecords; })
      if (!this.showTestRecords) {
        if (this.state.testAt > 0) {
          Text('最近测试 · ' + this.routeText(this.state.testRoute) + ' · ' + this.testTime() +
            ' · ' + this.state.testResult + ' · 用户确认：' + this.state.confirmation).id('wearable-test-summary')
            .fontSize(12).fontColor(MUTED).lineHeight(18).maxLines(2).width('100%')
        } else {
          Text('尚无测试记录，可展开后发送一条测试通知。')
            .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
        }
      }
      if (this.showTestRecords) {
        if (this.reminderEnabled) {
          Text('测试仅发送一条通知，可能引起腕上振动或响铃；不启动相机或守护，不写入坐姿统计。')
            .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
          Button(this.guarding ? '守护中不可测试' : this.state.cooldownRemainingMs > 0 ?
            '腕上冷却中，稍后再试' : '发送一条测试通知')
            .id('wearable-reminder-test').height(42).width('100%').fontSize(13)
            .fontColor(GREEN_DEEP).backgroundColor(GLASS_SOFT)
            .enabled(!this.locked && !this.guarding && this.state.canTest)
            .onClick(() => { this.onTest(); })
        } else {
          Text('开启腕上提醒后可发送单条测试，已有记录仍可查看。')
            .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
        }
        if (this.state.testAt > 0) {
          Divider().color(LINE_SOFT)
          Text('最近测试 · ' + this.routeText(this.state.testRoute) + ' · ' + this.testTime())
            .fontSize(13).fontColor(INK).width('100%')
          Text(this.state.testResult).id('wearable-test-result')
            .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
          Text('用户确认：' + this.state.confirmation).id('wearable-test-confirmation')
            .fontSize(13).fontColor(INK).width('100%')
          if (this.state.testModel.length > 0 || this.state.testSoftwareVersion.length > 0) {
            Text(this.state.testModel + ' · 固件 ' + (this.state.testSoftwareVersion || '未提供'))
              .fontSize(12).fontColor(MUTED).width('100%')
          }
          if (this.state.testFeedback.length > 0) {
            Text(this.state.testFeedback).fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
          }
          Text('请求成功不等于实际显示或振动；请根据腕上实际表现选择。')
            .fontSize(12).fontColor(MUTED).width('100%')
          Column({ space: 6 }) {
            this.ConfirmationButton(WearableTestConfirmation.VIBRATED)
            this.ConfirmationButton(WearableTestConfirmation.DISPLAYED)
            this.ConfirmationButton(WearableTestConfirmation.NOT_RECEIVED)
          }.width('100%')
        }
        if (this.state.diagnosticCount > 0 || this.state.testAt > 0) {
          Text('腕上记录仅本地保留，最多100条、24小时；展示最新5条，不计入业务提醒数。')
            .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
          ForEach(this.state.diagnostics.slice(0, 5), (diagnostic: WearableDiagnostic) => {
            Column({ space: 4 }) {
              Text(new Date(diagnostic.timestamp).toLocaleString() + ' · ' +
                (diagnostic.isTest ? '测试' : '正式') + ' · ' + this.routeText(diagnostic.route))
                .fontSize(12).fontColor(INK).lineHeight(18).width('100%')
              Text(diagnostic.result + (diagnostic.feedback.length > 0 ? ' · ' + diagnostic.feedback : '') +
                (diagnostic.errorCode !== 0 ? '（API ' + diagnostic.errorCode.toString() + '）' : '') +
                (diagnostic.feedbackErrorCode !== 0 ? '（回调 ' + diagnostic.feedbackErrorCode.toString() + '）' : ''))
                .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
              if (diagnostic.isTest) {
                Text(diagnostic.submitted ? '用户确认：' + diagnostic.confirmation : '未提交通知')
                  .fontSize(12).fontColor(MUTED).width('100%')
              }
            }.width('100%').padding({ top: 8, bottom: 8 }).border({ width: { bottom: 1 }, color: LINE_SOFT })
          }, (diagnostic: WearableDiagnostic) => diagnostic.eventId)
          Button('清除腕上诊断').id('wearable-reminder-clear').height(40).fontSize(13)
            .fontColor(MUTED).backgroundColor(GLASS_SOFT).enabled(!this.locked)
            .onClick(() => { this.onClear(); })
        }
      }
    }.width('100%').padding({ top: 16, bottom: 20 }).border({ width: { bottom: 1 }, color: LINE_SOFT })
  }

  @Builder
  private RouteButton(label: string, route: WearableReminderRoute) {
    Button(label + (route === this.reminderRoute ? ' · 已选' : ''))
      .id(route === WearableReminderRoute.NOTIFICATION_SYNC ? 'wearable-route-notification' : 'wearable-route-engine')
      .height(42).width('100%').fontSize(13).fontColor(GREEN_DEEP)
      .backgroundColor(route === this.reminderRoute ? GREEN_SOFT : GLASS_SOFT)
      .enabled(!this.locked && !this.guarding && !this.state.busy)
      .accessibilityText(label + (route === this.reminderRoute ? '，已选择' : '，选择此通道'))
      .onClick(() => { this.onRoute(route); })
  }

  @Builder
  private DeviceRow(device: WearableDeviceChoice, index: number) {
    Button({ type: ButtonType.Normal }) {
      Column({ space: 4 }) {
        Text((index + 1).toString() + '. ' + device.name +
          (device.routeId === this.state.selectedId ? ' · 已选择' : ''))
          .fontSize(14).fontColor(INK).width('100%')
        Text((device.model || '型号未提供') + ' · 固件 ' + (device.softwareVersion || '未提供') +
          (device.supported ? ' · 支持模板通知' : ' · 不支持模板通知'))
          .fontSize(12).fontColor(MUTED).lineHeight(18).width('100%')
      }.width('100%')
    }.width('100%').constraintSize({ minHeight: 60 }).padding(12).borderRadius(16)
      .backgroundColor(device.routeId === this.state.selectedId ? GREEN_SOFT : GLASS_SOFT)
      .enabled(!this.locked && !this.state.busy && device.supported)
      .accessibilityText(device.name + (device.supported ? '，选择为唯一提醒目标' : '，不支持模板通知'))
      .onClick(() => { this.onSelect(device.routeId); })
  }

  @Builder
  private ConfirmationButton(result: WearableTestConfirmation) {
    Button(result).height(40).width('100%').fontSize(13)
      .fontColor(this.state.confirmation === result ? GREEN_DEEP : INK)
      .backgroundColor(this.state.confirmation === result ? GREEN_SOFT : GLASS_SOFT)
      .enabled(!this.locked && this.state.canConfirmTest)
      .onClick(() => { this.onConfirm(result); })
  }
}
