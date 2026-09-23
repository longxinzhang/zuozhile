import { common } from '@kit.AbilityKit';
import { FloatingReading, floatingScore, floatingStatus } from '../models/FloatingStatus';
import { PostureFloatService } from '../services/PostureFloatService';
import { GREEN, INK, MUTED, GLASS_SOFT } from '../theme/ZuozhiTheme';

@Entry
@Component
struct PostureFloat {
  @StorageProp('floatScore') private score: number = 0;
  @StorageProp('floatSummary') private summary: string = '';
  @StorageProp('floatTimestamp') private timestamp: number = 0;
  @StorageProp('floatGuarding') private guarding: boolean = false;
  @StorageProp('floatSimulated') private simulated: boolean = false;
  @StorageProp('appForeground') private foreground: boolean = true;
  @StorageProp('floatNative') private nativeView: boolean = false;
  @State private now: number = Date.now();
  private timer: number = -1;

  aboutToAppear(): void {
    this.timer = setInterval(() => { this.now = Date.now(); }, 1000);
  }
  aboutToDisappear(): void {
    clearInterval(this.timer);
  }
  private reading(): FloatingReading {
    return { score: this.score, summary: this.summary, timestamp: this.timestamp, guarding: this.guarding,
      foreground: this.foreground, simulated: this.simulated };
  }
  private sampleTime(): string {
    return this.timestamp > 0 ? '上次采样 ' + new Date(this.timestamp).toLocaleTimeString() : '暂无采样';
  }
  private async returnToApp(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await context.startAbility({ bundleName: 'com.longxin.zuozhile', abilityName: 'EntryAbility' });
      await PostureFloatService.close();
    } catch (error) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '请从桌面打开坐直了' });
      } catch (ignored) {
      }
    }
  }
  build() {
    Column({ space: 10 }) {
      Row({ space: 8 }) {
        Image($r('app.media.brand_mark')).width(24).height(24).borderRadius(6)
        Text(this.nativeView ? '坐直了' : '坐直了 · 窗口预览').fontSize(14).fontColor(INK).layoutWeight(1)
        Button({ type: ButtonType.Circle }) {
          SymbolGlyph($r('sys.symbol.xmark')).fontSize(14).fontColor([MUTED])
        }.width(32).height(32).backgroundColor(GLASS_SOFT).accessibilityText('关闭浮窗')
          .onClick(() => { PostureFloatService.close(); })
      }.width('100%')
        .onTouch((event: TouchEvent) => { if (event.type === TouchType.Down) { PostureFloatService.move(); } })
      Row({ space: 12 }) {
        Text(floatingScore(this.reading(), this.now)).fontSize(42).fontWeight(FontWeight.Bold).fontColor(GREEN)
          .width(74).maxLines(1)
        Column({ space: 6 }) {
          Text(floatingStatus(this.reading(), this.now)).fontSize(14).fontColor(INK).maxLines(2)
          Text(this.sampleTime()).fontSize(11).fontColor(MUTED).maxLines(1)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
      }.width('100%')
      Button('返回坐直了').width('100%').height(36).fontSize(14).fontColor(GREEN).backgroundColor(GLASS_SOFT)
        .onClick(() => { this.returnToApp(); })
    }.width('100%').height('100%').padding({ top: this.nativeView ? 42 : 14, left: 16, right: 16, bottom: 14 })
      .justifyContent(FlexAlign.SpaceBetween).backgroundColor('#FAFCFD').borderRadius(24)
      .border({ width: 1, color: '#FFFFFF' })
  }
}
