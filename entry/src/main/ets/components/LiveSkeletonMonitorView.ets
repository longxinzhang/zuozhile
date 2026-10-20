import { common } from '@kit.AbilityKit';
import { LiveSkeletonPhase, LiveSkeletonState } from '../models/LiveSkeletonMonitor';
import { LiveSkeletonCameraSource } from '../services/LiveSkeletonCameraSource';
import { LiveSkeletonController } from '../services/LiveSkeletonController';
import { SkeletonDebugFrame } from '../services/SkeletonDebugFeed';
import { SkeletonFrameView } from './SkeletonDebugPanel';
import { ACTION_GREEN, APP_BG, BLUE, GLASS_SOFT, GREEN, INK, MUTED, RED } from '../theme/ZuozhiTheme';

@Component
export struct LiveSkeletonMonitorView {
  controller: LiveSkeletonController = new LiveSkeletonController();
  contextProvider: () => common.UIAbilityContext | undefined = (): common.UIAbilityContext | undefined => undefined;
  requestAccess: () => Promise<boolean> = async (): Promise<boolean> => false;
  canRun: () => boolean = (): boolean => false;
  onClose: () => void = (): void => {};
  @Prop @Watch('availabilityChanged') foreground: boolean = true;
  @Prop monitorState: LiveSkeletonState = new LiveSkeletonState();
  @State private withImage: boolean = false;
  @State private mirrored: boolean = true;
  private visible: boolean = false;

  aboutToAppear(): void {
    this.visible = true;
    this.withImage = false;
    this.controller.setIncludeImage(false);
  }

  aboutToDisappear(): void {
    this.visible = false;
    this.controller.stop();
  }

  private availabilityChanged(): void {
    if (!this.foreground) {
      this.controller.stop();
    }
  }

  private start(): void {
    if (!this.visible || !this.foreground || !this.canRun() || this.controller.isBusy()) {
      return;
    }
    const context = this.contextProvider();
    if (context === undefined) {
      const state = new LiveSkeletonState();
      state.phase = LiveSkeletonPhase.ERROR;
      state.detail = '无法获取相机上下文，请退出后重试';
      this.monitorState = state;
      return;
    }
    this.controller.setIncludeImage(this.withImage);
    this.controller.start(new LiveSkeletonCameraSource(context), this.requestAccess,
      (): boolean => this.visible && this.foreground && this.canRun());
  }

  private isActive(): boolean {
    return this.monitorState.phase === LiveSkeletonPhase.PREPARING ||
      this.monitorState.phase === LiveSkeletonPhase.RUNNING;
  }

  private actionText(): string {
    if (this.monitorState.phase === LiveSkeletonPhase.STOPPING) {
      return '正在停止';
    }
    if (this.monitorState.cleanupBlocked) {
      return '重试释放相机';
    }
    return this.isActive() ? '停止监看' : '开始实时监看';
  }

  build() {
    Column({ space: 12 }) {
      Row({ space: 12 }) {
        Column({ space: 4 }) {
          Text('实时骨骼监看').fontSize(24).fontWeight(FontWeight.Bold).fontColor(INK)
          Text('独立连续检测 · 不开启守护').fontSize(12).fontColor(MUTED)
        }.alignItems(HorizontalAlign.Start).layoutWeight(1)
        Button('返回').id('live-skeleton-close').height(40).fontSize(14)
          .fontColor(INK).backgroundColor(GLASS_SOFT).onClick((): void => { this.onClose(); })
      }.width('100%')
      Scroll() {
        Column({ space: 12 }) {
          Row({ space: 12 }) {
            Text(this.monitorState.fps.toFixed(1) + ' FPS').fontSize(20).fontWeight(FontWeight.Medium).fontColor(GREEN)
              .id('live-skeleton-fps')
            Blank()
            Text(this.monitorState.processingMs.toFixed(0) + ' ms / 帧').fontSize(12).fontColor(MUTED)
            Text(this.monitorState.frames.toString() + ' 帧').fontSize(12).fontColor(MUTED)
          }.width('100%')
          Stack() {
            if (this.monitorState.frame) {
              if (this.monitorState.frame.imageUrl.length === 0) {
                SkeletonFrameView({ frame: this.monitorState.frame, mirrored: this.mirrored })
              } else {
                ForEach([this.monitorState.frame], (frame: SkeletonDebugFrame) => {
                  SkeletonFrameView({ frame, mirrored: this.mirrored })
                }, (frame: SkeletonDebugFrame): string => frame.sequence.toString())
              }
            } else {
              Column({ space: 12 }) {
                Text(this.monitorState.phase === LiveSkeletonPhase.RUNNING ? '等待新的骨骼画面' : '连续骨骼画面')
                  .fontSize(18).fontColor('#FFFFFF')
                Text(this.monitorState.phase === LiveSkeletonPhase.RUNNING ? '请让头部、肩膀与上身入镜' : '点击下方按钮开始')
                  .fontSize(13).fontColor('#A6B5BE')
              }.width('100%').height('100%').justifyContent(FlexAlign.Center)
            }
          }.id('live-skeleton-viewport').width('100%').aspectRatio(0.75)
            .constraintSize({ maxHeight: 480 }).backgroundColor('#15191D').borderRadius(16).clip(true)
          Row({ space: 8 }) {
            Text(this.monitorState.frame ? this.monitorState.frame.points.length.toString() + '/17 可靠关键点' : '-- 关键点')
              .fontSize(12).fontColor(MUTED).layoutWeight(1)
            Text(this.monitorState.frame ? this.monitorState.frameAgeMs.toFixed(0) + ' ms 前更新' : '')
              .fontSize(12).fontColor(MUTED)
          }.width('100%')
          if (this.monitorState.frame && this.monitorState.frame.people > 1) {
            Text('检测到多人，仅显示最可靠的骨架').fontSize(12).fontColor(BLUE).width('100%')
          }
          Row({ space: 8 }) {
            Text('相机画面').fontSize(14).fontColor(INK)
            Toggle({ type: ToggleType.Switch, isOn: this.withImage }).id('live-skeleton-image-toggle')
              .selectedColor(GREEN).accessibilityText('叠加同帧相机画面')
              .onChange((value: boolean): void => {
                this.withImage = value;
                this.controller.setIncludeImage(value);
              })
            Blank()
            Text('镜像').fontSize(14).fontColor(INK)
            Toggle({ type: ToggleType.Switch, isOn: this.mirrored }).id('live-skeleton-mirror-toggle')
              .selectedColor(GREEN).accessibilityText('实时骨骼镜像')
              .onChange((value: boolean): void => { this.mirrored = value; })
          }.width('100%')
          Text(this.monitorState.detail).id('live-skeleton-status').fontSize(12).lineHeight(18).maxLines(3)
            .fontColor(this.monitorState.phase === LiveSkeletonPhase.ERROR ? RED : MUTED).width('100%')
          Text('不评分、不校准、不计统计、不发提醒；画面只在本机内存中，退出或后台即停止。')
            .fontSize(11).fontColor(MUTED).lineHeight(17).width('100%')
          Text('目标最高 10 FPS，按实际检测速度刷新；叠加相机画面会增加耗时。')
            .fontSize(11).fontColor(MUTED).lineHeight(17).width('100%')
        }.width('100%')
      }.width('100%').layoutWeight(1).scrollBar(BarState.Off)
      Button(this.actionText()).id('live-skeleton-action').width('100%').height(48).fontSize(16)
        .fontColor('#FFFFFF').backgroundColor(this.isActive() ? RED : ACTION_GREEN)
        .enabled(this.monitorState.phase !== LiveSkeletonPhase.STOPPING && (this.isActive() || this.foreground))
        .onClick((): void => {
          if (this.isActive() || this.monitorState.cleanupBlocked) {
            this.controller.stop();
          } else {
            this.start();
          }
        })
    }.width('100%').height('100%').constraintSize({ maxWidth: 760 })
      .padding({ left: 20, right: 20, top: 12, bottom: 12 })
      .backgroundColor(APP_BG)
  }
}
