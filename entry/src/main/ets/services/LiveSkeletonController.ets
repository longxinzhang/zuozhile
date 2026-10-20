import { systemDateTime } from '@kit.BasicServicesKit';
import { LiveSkeletonFrameSource, LiveSkeletonListener, LiveSkeletonPhase,
  LiveSkeletonState } from '../models/LiveSkeletonMonitor';
import { DebugJoint } from '../debug/SkeletonGeometry';
import { SkeletonDebugFrame } from './SkeletonDebugFeed';

export class LiveSkeletonController {
  private current: LiveSkeletonState = new LiveSkeletonState();
  private listener?: LiveSkeletonListener;
  private active: boolean = false;
  private generation: number = 0;
  private blockedSource?: LiveSkeletonFrameSource;
  private operation?: Promise<void>;
  private allowed: () => boolean = (): boolean => false;
  private includeImage: boolean = false;
  private imageRevision: number = 0;
  private frameTimes: number[] = [];
  private lastFrameAt: number = 0;
  private delayTimer: number = -1;
  private statusTimer: number = -1;
  private wake?: () => void;

  observe(listener: LiveSkeletonListener): void {
    this.listener = listener;
    this.emit();
  }

  unobserve(): void {
    this.listener = undefined;
  }

  isBusy(): boolean {
    return this.active || this.current.phase === LiveSkeletonPhase.STOPPING || this.current.cleanupBlocked;
  }

  isRequested(): boolean {
    return this.active;
  }

  setIncludeImage(value: boolean): void {
    if (value !== this.includeImage) {
      this.includeImage = value;
      this.imageRevision++;
      this.current.frame = undefined;
      this.current.frameAgeMs = 0;
      this.emit();
    }
  }

  start(source: LiveSkeletonFrameSource, requestAccess: () => Promise<boolean>, allowed: () => boolean): void {
    if (this.isBusy() || !allowed()) {
      return;
    }
    this.active = true;
    const runId = ++this.generation;
    this.allowed = allowed;
    this.frameTimes = [];
    this.lastFrameAt = 0;
    this.current = new LiveSkeletonState();
    this.current.phase = LiveSkeletonPhase.PREPARING;
    this.current.detail = '正在准备相机与骨骼检测';
    this.operation = Promise.resolve().then((): Promise<void> => this.run(source, requestAccess, runId));
    this.emit();
  }

  stop(): Promise<void> {
    if (this.active) {
      this.active = false;
      this.generation++;
      this.current.phase = LiveSkeletonPhase.STOPPING;
      this.current.detail = '正在释放相机';
      this.current.frame = undefined;
      this.current.fps = 0;
      this.current.frameAgeMs = 0;
      this.cancelTimers();
      this.emit();
    } else if (this.blockedSource !== undefined && this.operation === undefined) {
      const source = this.blockedSource;
      this.current.phase = LiveSkeletonPhase.STOPPING;
      this.current.detail = '正在重试释放相机';
      this.operation = Promise.resolve().then((): Promise<void> => this.retryCleanup(source));
      this.emit();
    }
    return this.operation ?? Promise.resolve();
  }

  private isCurrent(runId: number): boolean {
    return this.active && this.generation === runId && this.allowed();
  }

  private async run(source: LiveSkeletonFrameSource, requestAccess: () => Promise<boolean>,
    runId: number): Promise<void> {
    let failure = '';
    try {
      if (!this.isCurrent(runId)) {
        return;
      }
      const granted = await requestAccess();
      if (!this.isCurrent(runId)) {
        return;
      }
      if (!granted) {
        throw new Error('未获得相机权限，请允许后重试');
      }
      await source.prepare((): boolean => this.isCurrent(runId));
      if (!this.isCurrent(runId)) {
        return;
      }
      this.current.phase = LiveSkeletonPhase.RUNNING;
      this.current.detail = source.statusDetail();
      this.statusTimer = setInterval((): void => { this.refreshStatus(runId); }, 250);
      this.emit();
      while (this.isCurrent(runId)) {
        const startedAt = this.now();
        const revision = this.imageRevision;
        const frame = await source.nextFrame(this.includeImage, (): boolean => this.isCurrent(runId));
        if (!this.isCurrent(runId)) {
          break;
        }
        const completedAt = this.now();
        this.current.processingMs = Math.max(0, completedAt - startedAt);
        if (frame !== undefined && revision === this.imageRevision) {
          this.lastFrameAt = completedAt;
          this.frameTimes.push(completedAt);
          this.current.frame = this.copyFrame(frame, this.includeImage);
          this.current.frames++;
          this.current.frameAgeMs = 0;
          this.current.detail = source.statusDetail();
          this.updateFps(completedAt);
          this.emit();
        }
        if (this.isCurrent(runId)) {
          await this.wait(Math.max(16, 100 - (this.now() - startedAt)));
        }
      }
    } catch (error) {
      if (this.isCurrent(runId)) {
        failure = error instanceof Error ? error.message : '连续骨骼检测失败，请停止后重试';
      }
    } finally {
      this.active = false;
      this.generation++;
      this.cancelTimers();
      this.current.phase = LiveSkeletonPhase.STOPPING;
      this.current.frame = undefined;
      this.current.fps = 0;
      this.current.frameAgeMs = 0;
      this.current.detail = '正在释放相机';
      this.emit();
      try {
        await source.dispose();
      } catch (error) {
        this.blockedSource = source;
        this.current.cleanupBlocked = true;
        failure = failure.length > 0 ? failure + '；相机未确认释放，请重试释放' : '相机未确认释放，请重试释放';
      }
      this.operation = undefined;
      this.current.phase = failure.length > 0 ? LiveSkeletonPhase.ERROR : LiveSkeletonPhase.IDLE;
      this.current.detail = failure.length > 0 ? failure : '已停止，相机已释放；点击开始可重新监看';
      this.emit();
    }
  }

  private async retryCleanup(source: LiveSkeletonFrameSource): Promise<void> {
    try {
      await source.dispose();
      this.blockedSource = undefined;
      this.current.cleanupBlocked = false;
      this.current.phase = LiveSkeletonPhase.IDLE;
      this.current.detail = '相机已释放，可以重新监看';
    } catch (error) {
      this.current.phase = LiveSkeletonPhase.ERROR;
      this.current.detail = '相机仍未释放，请重试释放或重启应用；守护暂不可用';
    } finally {
      this.operation = undefined;
      this.emit();
    }
  }

  private refreshStatus(runId: number): void {
    if (runId !== this.generation) {
      return;
    }
    if (!this.isCurrent(runId)) {
      this.stop();
      return;
    }
    const now = this.now();
    this.current.frameAgeMs = this.lastFrameAt > 0 ? Math.max(0, now - this.lastFrameAt) : 0;
    if (this.current.frameAgeMs > 2000) {
      this.current.frame = undefined;
      this.current.detail = '画面已过期，等待新的检测帧';
    }
    this.updateFps(now);
    this.emit();
  }

  private updateFps(now: number): void {
    this.frameTimes = this.frameTimes.filter((time: number): boolean => time >= now - 2000 && time <= now);
    const count = this.frameTimes.length;
    const duration = count > 1 ? this.frameTimes[count - 1] - this.frameTimes[0] : 0;
    this.current.fps = duration > 0 && now - this.lastFrameAt < 1000 ? (count - 1) * 1000 / duration : 0;
  }

  private wait(delay: number): Promise<void> {
    return new Promise<void>((resolve): void => {
      this.wake = (): void => { resolve(); };
      this.delayTimer = setTimeout((): void => {
        this.delayTimer = -1;
        this.wake = undefined;
        resolve();
      }, delay);
    });
  }

  private cancelTimers(): void {
    if (this.delayTimer >= 0) {
      clearTimeout(this.delayTimer);
      this.delayTimer = -1;
    }
    if (this.statusTimer >= 0) {
      clearInterval(this.statusTimer);
      this.statusTimer = -1;
    }
    const wake = this.wake;
    this.wake = undefined;
    wake?.();
  }

  private now(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  }

  private emit(): void {
    const state = new LiveSkeletonState();
    state.phase = this.current.phase;
    state.frame = this.current.frame === undefined ? undefined : this.copyFrame(this.current.frame, this.includeImage);
    state.frames = this.current.frames;
    state.fps = this.current.fps;
    state.processingMs = this.current.processingMs;
    state.frameAgeMs = this.current.frameAgeMs;
    state.cleanupBlocked = this.current.cleanupBlocked;
    state.detail = this.current.detail;
    try {
      this.listener?.(state);
    } catch (error) {
    }
  }

  private copyFrame(frame: SkeletonDebugFrame, includeImage: boolean): SkeletonDebugFrame {
    const points: DebugJoint[] = frame.points.map((point: DebugJoint): DebugJoint => {
      return { type: point.type, x: point.x, y: point.y, confidence: point.confidence };
    });
    return { sequence: frame.sequence, timestamp: frame.timestamp, width: frame.width, height: frame.height,
      people: frame.people, points, imageUrl: includeImage ? frame.imageUrl : '',
      imageError: includeImage && frame.imageError };
  }
}
