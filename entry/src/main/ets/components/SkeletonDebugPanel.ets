import { SkeletonDebugFeed, SkeletonDebugFrame } from '../services/SkeletonDebugFeed';
import { DebugBone, DebugPoint, skeletonDrawing } from '../debug/SkeletonGeometry';
import { BLUE, GREEN, GREEN_DEEP, GREEN_SOFT, INK, LINE_SOFT, MUTED, RED } from '../theme/ZuozhiTheme';

@Component
struct SkeletonFrameView {
  @Prop frame: SkeletonDebugFrame;
  @Prop @Watch('draw') mirrored: boolean = true;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(true));
  private ready: boolean = false;
  private imageReady: boolean = false;
  @State private imageFailed: boolean = false;

  private draw(): void {
    if (!this.ready) {
      return;
    }
    const ctx = this.context;
    ctx.clearRect(0, 0, ctx.width, ctx.height);
    if (this.frame.imageUrl.length > 0 && !this.imageReady && !this.imageFailed) {
      return;
    }
    const drawing = skeletonDrawing(this.frame.points, this.frame.width, this.frame.height,
      ctx.width, ctx.height, this.mirrored);
    ctx.lineCap = 'round';
    drawing.bones.forEach((bone: DebugBone) => {
      ctx.beginPath();
      ctx.moveTo(bone.start.x, bone.start.y);
      ctx.lineTo(bone.end.x, bone.end.y);
      ctx.strokeStyle = '#121A20';
      ctx.lineWidth = 7;
      ctx.stroke();
      ctx.strokeStyle = bone.side === 1 ? '#68E2BE' : '#8CBFFF';
      ctx.lineWidth = 3;
      ctx.stroke();
    });
    drawing.joints.forEach((point: DebugPoint) => {
      ctx.beginPath();
      ctx.arc(point.x, point.y, 4.5, 0, Math.PI * 2);
      ctx.fillStyle = '#FFFFFF';
      ctx.fill();
      ctx.lineWidth = 2;
      ctx.strokeStyle = '#15212A';
      ctx.stroke();
    });
  }

  build() {
    Stack({ alignContent: Alignment.Center }) {
      if (this.frame.imageUrl.length > 0 && !this.imageFailed) {
        Image(this.frame.imageUrl).width('100%').height('100%').objectFit(ImageFit.Contain)
          .syncLoad(true).scale({ x: this.mirrored ? -1 : 1, y: 1 })
          .onComplete(() => { this.imageReady = true; this.draw(); })
          .onError(() => { this.imageFailed = true; this.draw(); })
          .accessibilityLevel('no')
      }
      Canvas(this.context).width('100%').height('100%').hitTestBehavior(HitTestMode.None)
        .onReady(() => { this.ready = true; this.draw(); })
        .onAreaChange(() => { this.draw(); })
        .accessibilityText('人体骨骼，' + this.frame.points.length.toString() + '个可靠关键点')
      if (this.frame.points.length === 0) {
        Text('未检测到可靠骨骼').fontSize(14).fontColor('#FFFFFF')
          .padding(12).backgroundColor('#C0202428').borderRadius(8)
      }
      if (this.frame.imageError || this.imageFailed) {
        Text('相机图像暂不可用').fontSize(12).fontColor('#F0BE62')
          .align(Alignment.Bottom).margin({ bottom: 12 })
      }
    }.width('100%').height('100%').backgroundColor('#15191D').clip(true)
  }
}

@Component
export struct SkeletonDebugPanel {
  @Prop @Watch('availabilityChanged') active: boolean = false;
  @Prop @Watch('availabilityChanged') realSource: boolean = true;
  @Prop guarding: boolean = false;
  @Prop locked: boolean = false;
  @Prop intervalMs: number = 2000;
  requestFrame: () => Promise<void> = async (): Promise<void> => {};
  @State private isMonitoring: boolean = false;
  @State private withImage: boolean = false;
  @State private mirrored: boolean = true;
  @State private busy: boolean = false;
  @State private frame: SkeletonDebugFrame | undefined = undefined;
  @State private error: string = '';
  @State private now: number = Date.now();
  private token: number = 0;
  private timer: number = -1;

  aboutToDisappear(): void {
    this.close();
  }

  private availabilityChanged(): void {
    if (!this.active || !this.realSource) {
      this.close();
    }
  }

  private close(): void {
    SkeletonDebugFeed.disconnect(this.token);
    this.token = 0;
    this.isMonitoring = false;
    this.withImage = false;
    this.frame = undefined;
    this.error = '';
    if (this.timer >= 0) {
      clearInterval(this.timer);
      this.timer = -1;
    }
  }

  private connect(): void {
    SkeletonDebugFeed.disconnect(this.token);
    this.frame = undefined;
    this.error = '';
    if (!this.isMonitoring || !this.active || !this.realSource) {
      return;
    }
    this.token = SkeletonDebugFeed.connect((frame: SkeletonDebugFrame | undefined, error: string) => {
      this.frame = frame;
      this.error = error;
      this.now = Date.now();
    }, this.withImage);
    if (this.timer < 0) {
      this.timer = setInterval(() => {
        this.now = Date.now();
        if (this.guarding && this.frame && this.now - this.frame.timestamp > Math.max(6000, this.intervalMs * 2 + 1000)) {
          this.frame = undefined;
          this.error = '画面已过期，等待下一帧';
        }
      }, 1000);
    }
  }

  private async capture(): Promise<void> {
    if (this.busy || this.locked || this.guarding || !this.isMonitoring || !this.active || !this.realSource) {
      return;
    }
    this.busy = true;
    try {
      await this.requestFrame();
    } catch (ignore) {
      if (this.isMonitoring && this.active) {
        this.frame = undefined;
        this.error = '采集失败，请重试';
      }
    } finally {
      this.busy = false;
    }
  }

  private frameStatus(): string {
    if (this.busy) {
      return '采集中';
    }
    if (!this.frame) {
      return '等待检测帧';
    }
    const age = Math.max(0, Math.floor((this.now - this.frame.timestamp) / 1000));
    return (this.guarding ? '守护采样' : '单帧检查') + ' · ' + age.toString() + ' 秒前';
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 8 }) {
        SymbolGlyph($r('sys.symbol.person_filled_viewfinder')).fontSize(20).fontColor([BLUE])
        Text('骨骼监看').fontSize(16).fontWeight(FontWeight.Medium).fontColor(INK).layoutWeight(1)
        Toggle({ type: ToggleType.Switch, isOn: this.isMonitoring }).id('skeleton-debug-toggle')
          .selectedColor(GREEN).accessibilityText('骨骼监看')
          .enabled(this.isMonitoring || (this.active && this.realSource && !this.locked))
          .onChange((value: boolean) => {
            if (value) { this.isMonitoring = true; this.connect(); } else { this.close(); }
          })
      }.width('100%').height(44)
      if (!this.realSource) {
        Text('模拟源无真实骨骼').fontSize(12).fontColor(MUTED).width('100%')
      }
      if (this.isMonitoring) {
        Row({ space: 10 }) {
          Text('相机画面').fontSize(13).fontColor(INK)
          Toggle({ type: ToggleType.Switch, isOn: this.withImage }).id('skeleton-image-toggle')
            .selectedColor(GREEN).accessibilityText('叠加相机画面').enabled(!this.busy)
            .onChange((value: boolean) => { this.withImage = value; this.connect(); })
          Blank()
          Text('镜像').fontSize(13).fontColor(INK)
          Toggle({ type: ToggleType.Switch, isOn: this.mirrored }).id('skeleton-mirror-toggle')
            .selectedColor(GREEN).accessibilityText('骨骼镜像')
            .onChange((value: boolean) => { this.mirrored = value; })
        }.width('100%').height(40)
        Row({ space: 8 }) {
          Text(this.frameStatus()).fontSize(12).fontColor(MUTED).layoutWeight(1)
          Button() {
            Row({ space: 6 }) {
              SymbolGlyph($r('sys.symbol.camera')).fontSize(15).fontColor([GREEN_DEEP])
              Text('采集一帧').fontSize(13).fontColor(GREEN_DEEP)
            }
          }.id('skeleton-capture').height(36).padding({ left: 12, right: 12 }).backgroundColor(GREEN_SOFT)
            .enabled(!this.locked && !this.busy && !this.guarding)
            .onClick(() => { this.capture(); })
        }.width('100%')
        Stack() {
          if (this.frame) {
            // Recreate both layers together; never overlay a new skeleton on an old decoded photo.
            ForEach([this.frame], (frame: SkeletonDebugFrame) => {
              SkeletonFrameView({ frame, mirrored: this.mirrored })
            }, (frame: SkeletonDebugFrame) => frame.sequence.toString())
          } else {
            Column({ space: 12 }) {
              SymbolGlyph($r('sys.symbol.viewfinder_square')).fontSize(32).fontColor(['#98A6AE'])
              Text(this.error.length > 0 ? this.error : '等待检测帧').fontSize(14).fontColor('#C9D1D7')
            }.width('100%').height('100%').justifyContent(FlexAlign.Center)
          }
        }.id('skeleton-viewport').width('100%').aspectRatio(0.75).backgroundColor('#15191D').borderRadius(8).clip(true)
        Row() {
          Text(this.frame ? this.frame.points.length.toString() + '/17 关键点' : '-- 关键点')
            .fontSize(12).fontColor(MUTED).layoutWeight(1)
          Text(this.frame ? this.frame.width.toString() + ' × ' + this.frame.height.toString() : '')
            .fontSize(12).fontColor(MUTED)
        }.width('100%')
        if (this.frame && this.frame.people > 1) {
          Text('检测到 ' + this.frame.people.toString() + ' 人，仅显示算法选中骨架')
            .fontSize(12).fontColor(RED).width('100%')
        }
        Text(this.guarding ? '检测间隔 ' + (this.intervalMs / 1000).toString() + ' 秒' : '单帧检查 · 不计入统计')
          .fontSize(12).fontColor(MUTED).width('100%')
        Text('仅本机内存 · 退出即清除').fontSize(12).fontColor(MUTED).width('100%')
      }
    }.width('100%').padding({ top: 10, bottom: 16 }).border({ width: { bottom: 1 }, color: LINE_SOFT })
  }
}
