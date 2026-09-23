import { common } from '@kit.AbilityKit';
import { FloatingReading, floatingScore, floatingStatus, hasFloatingReading } from '../models/FloatingStatus';
import { PostureFloatService } from '../services/PostureFloatService';
import { GREEN, INK, MUTED, GLASS_SOFT, LINE_SOFT, scoreColor } from '../theme/ZuozhiTheme';
import { ImmersiveSurface } from '../theme/ImmersiveSurface';

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
  @StorageProp('floatAvoidTop') private avoidTop: number = 0;
  @StorageProp('floatAvoidBottom') private avoidBottom: number = 0;
  @StorageProp('floatSitLabel') private sitLabel: string = '';
  @StorageProp('floatChinLabel') private chinLabel: string = '';
  @StorageProp('floatMouthLabel') private mouthLabel: string = '';
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
    return this.timestamp > 0 && Number.isFinite(this.timestamp) ?
      '上次采样 ' + new Date(this.timestamp).toLocaleTimeString() : '暂无有效采样';
  }
  private async returnToApp(): Promise<void> {
    const context = this.getUIContext().getHostContext() as common.UIAbilityContext;
    try {
      await PostureFloatService.restore(context);
    } catch (error) {
      try {
        this.getUIContext().getPromptAction().showToast({ message: '请从桌面打开坐直了' });
      } catch (ignored) {
      }
    }
  }
  build() {
    Scroll() {
      Column({ space: 12 }) {
        Row({ space: 6 }) {
          Row({ space: 6 }) {
            Image($r('app.media.brand_mark')).width(22).height(22)
            Text(this.nativeView ? '坐直了' : '坐直了 · 应用内').fontSize(12).fontColor(INK).maxLines(1)
          }.layoutWeight(1).height(30)
            .onTouch((event: TouchEvent) => {
              if (!this.nativeView && event.type === TouchType.Down) { PostureFloatService.move(); }
            })
          if (!this.nativeView) {
            Button({ type: ButtonType.Circle }) {
              SymbolGlyph($r('sys.symbol.xmark')).fontSize(12).fontColor([MUTED])
            }.width(30).height(30).backgroundColor(GLASS_SOFT).accessibilityText('关闭浮窗')
              .onClick(() => { PostureFloatService.close(); })
          }
        }.width('100%')
        Row({ space: 10 }) {
          Text(floatingScore(this.reading(), this.now)).fontSize(40).fontWeight(FontWeight.Bold)
            .fontColor(hasFloatingReading(this.reading(), this.now) ? scoreColor(this.score) : MUTED)
            .width(74).maxLines(1).minFontSize(30).maxFontSize(40)
          Column({ space: 5 }) {
            Text(floatingStatus(this.reading(), this.now)).fontSize(13).fontColor(INK).maxLines(2)
            Text(this.sampleTime()).fontSize(10).fontColor(MUTED).maxLines(1)
          }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        }.width('100%')
        Row({ space: 8 }) {
          FloatingMetric({ title: '坐姿', label: hasFloatingReading(this.reading(), this.now) ? this.sitLabel : '--' })
          FloatingMetric({ title: '抬头', label: hasFloatingReading(this.reading(), this.now) ? this.chinLabel : '--' })
          FloatingMetric({ title: '嘴巴', label: hasFloatingReading(this.reading(), this.now) ? this.mouthLabel : '--' })
        }.width('100%').padding({ top: 8 }).border({ width: { top: 1 }, color: LINE_SOFT })
        Button('返回坐直了').width('100%').height(34).fontSize(13).fontColor(GREEN).backgroundColor(GLASS_SOFT)
          .attributeModifier(new ImmersiveSurface('#18138654'))
          .onClick(() => { this.returnToApp(); })
      }.width('100%').padding({
        top: this.nativeView ? Math.max(12, this.getUIContext().px2vp(this.avoidTop)) : 10,
        left: 14, right: 14,
        bottom: this.nativeView ? Math.max(12, this.getUIContext().px2vp(this.avoidBottom)) : 10
      })
    }.width('100%').height('100%').scrollBar(BarState.Off)
      .linearGradient({ angle: 120, colors: [['#FCFEFF', 0], ['#EDF7F3', 1]] }).borderRadius(24)
  }

}

@Component
struct FloatingMetric {
  @Prop title: string = '';
  @Prop label: string = '--';
  build() {
    Column({ space: 4 }) {
      Text(this.title).fontSize(10).fontColor(MUTED)
      Text(this.label)
        .fontSize(11).fontColor(INK).maxLines(2).height(30).lineHeight(15)
    }.layoutWeight(1).alignItems(HorizontalAlign.Start)
  }
}
