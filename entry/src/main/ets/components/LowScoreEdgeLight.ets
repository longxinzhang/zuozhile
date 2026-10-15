import { AnimatorOptions, AnimatorResult, ColorMetrics } from '@kit.ArkUI';
import { LowScoreLevel } from '../models/LowScoreReminder';
import { EdgeGlowStop, EdgeGlowWedge, edgeGlowStops, edgeGlowWedges } from '../models/EdgeLightGeometry';

@Component
export struct LowScoreEdgeLight {
  @Prop @Watch('refreshEffect') level: LowScoreLevel = LowScoreLevel.NORMAL;
  @Prop @Watch('refreshEffect') effectEnabled: boolean = true;
  @Prop @Watch('refreshEffect') reduceMotion: boolean = false;
  @Prop @Watch('refreshEffect') active: boolean = true;
  @StorageProp('appColorMode') @Watch('draw') private colorMode: number = -1;
  @StorageProp('glowWindowWidthPx') @Watch('resizeDrawing') private windowWidthPx: number = 0;
  @StorageProp('glowWindowHeightPx') @Watch('resizeDrawing') private windowHeightPx: number = 0;
  @State private drawingWidth: Length = '100%';
  @State private drawingHeight: Length = '100%';
  @State private edgeAlpha: number = 0;
  @State @Watch('draw') private renderedLevel: LowScoreLevel = LowScoreLevel.NORMAL;
  private context: CanvasRenderingContext2D = new CanvasRenderingContext2D(new RenderingContextSettings(false));
  private canvasReady: boolean = false;
  private attached: boolean = false;
  private generation: number = 0;
  private effectAnimator: AnimatorResult | undefined = undefined;

  aboutToAppear(): void {
    this.attached = true;
    this.resizeDrawing();
    this.refreshEffect();
  }

  aboutToDisappear(): void {
    this.attached = false;
    this.canvasReady = false;
    this.cancelEffect();
    this.edgeAlpha = 0;
    this.renderedLevel = LowScoreLevel.NORMAL;
  }

  private cancelEffect(): void {
    this.generation += 1;
    const animator = this.effectAnimator;
    this.effectAnimator = undefined;
    animator?.cancel();
  }

  private refreshEffect(): void {
    this.cancelEffect();
    if (!this.attached || !this.active || !this.effectEnabled) {
      this.edgeAlpha = 0;
      this.renderedLevel = LowScoreLevel.NORMAL;
      return;
    }
    if (this.reduceMotion) {
      this.renderedLevel = this.level;
      this.edgeAlpha = this.level === LowScoreLevel.NORMAL ? 0 :
        (this.level === LowScoreLevel.LIGHT ? 0.5 : 0.72);
      this.draw();
      return;
    }
    if (this.level === LowScoreLevel.NORMAL) {
      this.fadeAlpha(0, 250, (): void => { this.renderedLevel = LowScoreLevel.NORMAL; });
      return;
    }
    const target = this.level;
    const targetAlpha = target === LowScoreLevel.LIGHT ? 0.3 : 0.38;
    const sameVisual = this.renderedLevel === target ||
      this.renderedLevel >= LowScoreLevel.MEDIUM && target >= LowScoreLevel.MEDIUM;
    if (this.renderedLevel === LowScoreLevel.NORMAL || sameVisual) {
      this.renderedLevel = target;
      this.draw();
      this.fadeAlpha(targetAlpha, 250, (): void => { this.startBreathing(); });
    } else {
      this.fadeAlpha(0, 125, (): void => {
        this.renderedLevel = target;
        this.draw();
        this.fadeAlpha(targetAlpha, 125, (): void => { this.startBreathing(); });
      });
    }
  }

  private fadeAlpha(targetAlpha: number, duration: number, completed: () => void): void {
    const generation = this.generation;
    const startAlpha = this.edgeAlpha;
    if (startAlpha === targetAlpha) {
      completed();
      return;
    }
    const options: AnimatorOptions = {
      duration,
      easing: 'ease-in-out',
      delay: 0,
      fill: 'forwards',
      direction: 'normal',
      iterations: 1,
      begin: 0,
      end: 1
    };
    const animator = this.getUIContext().createAnimator(options);
    animator.onFrame = (progress: number): void => {
      if (generation !== this.generation || !this.attached || !this.active || !this.effectEnabled) {
        return;
      }
      this.edgeAlpha = startAlpha + (targetAlpha - startAlpha) * progress;
    };
    animator.onFinish = (): void => {
      if (generation !== this.generation || !this.attached || !this.active || !this.effectEnabled) {
        return;
      }
      this.cancelEffect();
      this.edgeAlpha = targetAlpha;
      completed();
    };
    this.effectAnimator = animator;
    animator.play();
  }

  private startBreathing(): void {
    if (!this.attached || !this.active || !this.effectEnabled || this.reduceMotion ||
      this.level === LowScoreLevel.NORMAL) {
      return;
    }
    const generation = this.generation;
    const light = this.level === LowScoreLevel.LIGHT;
    const options: AnimatorOptions = {
      duration: light ? 1500 : 1000,
      easing: 'ease-in-out',
      delay: 0,
      fill: 'forwards',
      direction: 'alternate',
      iterations: -1,
      begin: light ? 0.3 : 0.38,
      end: light ? 0.78 : 0.94
    };
    const animator = this.getUIContext().createAnimator(options);
    animator.onFrame = (value: number): void => {
      if (generation !== this.generation || !this.attached || !this.active || !this.effectEnabled ||
        this.reduceMotion || this.level === LowScoreLevel.NORMAL) {
        return;
      }
      this.edgeAlpha = value;
    };
    this.effectAnimator = animator;
    animator.play();
  }

  private draw(): void {
    if (!this.canvasReady || !this.attached) {
      return;
    }
    const ctx = this.context;
    const width = ctx.width;
    const height = ctx.height;
    ctx.clearRect(0, 0, width, height);
    if (!this.active || !this.effectEnabled || this.renderedLevel === LowScoreLevel.NORMAL) {
      return;
    }
    const strong = this.renderedLevel >= LowScoreLevel.MEDIUM;
    let color: ColorMetrics = ColorMetrics.rgba(217, 83, 76);
    try {
      this.getUIContext().runScopedTask((): void => {
        color = ColorMetrics.resourceColor(strong ?
          $r('app.color.low_score_edge_strong') : $r('app.color.low_score_edge_light'));
      });
    } catch (error) {
      color = this.colorMode === 0 ?
        (strong ? ColorMetrics.rgba(240, 128, 121) : ColorMetrics.rgba(217, 140, 136)) :
        (strong ? ColorMetrics.rgba(217, 83, 76) : ColorMetrics.rgba(233, 150, 145));
    }
    if (this.reduceMotion) {
      ctx.strokeStyle = color.color;
      const lineWidth = strong ? 2 : 1.5;
      ctx.lineWidth = lineWidth;
      const inset = lineWidth / 2;
      ctx.strokeRect(inset, inset, width - lineWidth, height - lineWidth);
      return;
    }
    const stops = edgeGlowStops(strong);
    edgeGlowWedges(width, height).forEach((wedge: EdgeGlowWedge): void => {
      const gradient = ctx.createLinearGradient(wedge.start.x, wedge.start.y, wedge.end.x, wedge.end.y);
      stops.forEach((stop: EdgeGlowStop): void => {
        gradient.addColorStop(stop.offset, ColorMetrics.rgba(color.red, color.green, color.blue, stop.alpha).color);
      });
      ctx.fillStyle = gradient;
      ctx.beginPath();
      ctx.moveTo(wedge.points[0].x, wedge.points[0].y);
      for (let index = 1; index < wedge.points.length; index += 1) {
        ctx.lineTo(wedge.points[index].x, wedge.points[index].y);
      }
      ctx.closePath();
      ctx.fill();
    });
  }

  private resizeDrawing(): void {
    if (!this.attached) {
      return;
    }
    if (this.windowWidthPx > 0 && this.windowHeightPx > 0) {
      const ui = this.getUIContext();
      this.drawingWidth = ui.px2vp(this.windowWidthPx);
      this.drawingHeight = ui.px2vp(this.windowHeightPx);
    }
    this.draw();
  }

  build() {
    Canvas(this.context)
      .width(this.drawingWidth).height(this.drawingHeight)
      .align(Alignment.TopStart)
      .backgroundColor(Color.Transparent).opacity(this.active && this.effectEnabled ? this.edgeAlpha : 0)
      .hitTestBehavior(HitTestMode.None).accessibilityLevel('no').id('low-score-screen-glow')
      .onReady(() => { this.canvasReady = true; this.draw(); })
      .onAreaChange(() => { this.draw(); })
  }
}
