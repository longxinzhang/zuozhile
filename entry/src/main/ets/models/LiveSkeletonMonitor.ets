import { SkeletonDebugFrame } from '../services/SkeletonDebugFeed';

export enum LiveSkeletonPhase {
  IDLE = 'idle',
  PREPARING = 'preparing',
  RUNNING = 'running',
  STOPPING = 'stopping',
  ERROR = 'error'
}

export class LiveSkeletonState {
  phase: LiveSkeletonPhase = LiveSkeletonPhase.IDLE;
  frame: SkeletonDebugFrame | undefined = undefined;
  frames: number = 0;
  fps: number = 0;
  processingMs: number = 0;
  frameAgeMs: number = 0;
  cleanupBlocked: boolean = false;
  detail: string = '点击开始，连续查看真实骨骼';
}

export interface LiveSkeletonFrameSource {
  prepare(isCurrent: () => boolean): Promise<void>;
  nextFrame(includeImage: boolean, isCurrent: () => boolean): Promise<SkeletonDebugFrame | undefined>;
  dispose(): Promise<void>;
  statusDetail(): string;
}

export type LiveSkeletonListener = (state: LiveSkeletonState) => void;
