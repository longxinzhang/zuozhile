import { skeletonDetection } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { util } from '@kit.ArkTS';
import { DebugJoint, visibleJoints } from '../debug/SkeletonGeometry';

export interface SkeletonDebugFrame {
  sequence: number;
  timestamp: number;
  width: number;
  height: number;
  people: number;
  points: DebugJoint[];
  imageUrl: string;
  imageError: boolean;
}

export type SkeletonDebugListener = (frame: SkeletonDebugFrame | undefined, error: string) => void;

export class SkeletonDebugFeed {
  private static generation: number = 0;
  private static sequence: number = 0;
  private static listener?: SkeletonDebugListener;
  private static includeImage: boolean = false;

  static connect(listener: SkeletonDebugListener, includeImage: boolean): number {
    SkeletonDebugFeed.generation++;
    SkeletonDebugFeed.listener = listener;
    SkeletonDebugFeed.includeImage = includeImage;
    return SkeletonDebugFeed.generation;
  }

  static disconnect(token: number): void {
    if (token === SkeletonDebugFeed.generation) {
      SkeletonDebugFeed.generation++;
      SkeletonDebugFeed.listener = undefined;
      SkeletonDebugFeed.includeImage = false;
    }
  }

  static session(): number {
    return SkeletonDebugFeed.listener ? SkeletonDebugFeed.generation : 0;
  }

  static fail(message: string): void {
    try {
      SkeletonDebugFeed.listener?.(undefined, message);
    } catch (ignore) {
    }
  }

  static async publish(token: number, pixelMap: image.PixelMap,
    selected: skeletonDetection.Skeleton | undefined, people: number, timestamp: number): Promise<void> {
    if (token === 0 || token !== SkeletonDebugFeed.session()) {
      return;
    }
    let packer: image.ImagePacker | undefined = undefined;
    try {
      const info = pixelMap.getImageInfoSync();
      const width = info.size.width;
      const height = info.size.height;
      if (width <= 0 || height <= 0 || width * height > 4096 * 4096) {
        throw new Error('Invalid debug frame dimensions');
      }
      const points: DebugJoint[] = [];
      selected?.points?.forEach((point: skeletonDetection.SkeletonPoint) => {
        if (point.point) {
          points.push({ type: point.type, x: point.point.x, y: point.point.y, confidence: point.score });
        }
      });
      let imageUrl = '';
      let imageError = false;
      if (SkeletonDebugFeed.includeImage) {
        try {
          packer = image.createImagePacker();
          // Encode only the already-rotated detection frame, in memory, before its owner releases it.
          const buffer = await packer.packToData(pixelMap, { format: 'image/jpeg', quality: 75 });
          const encoded = await new util.Base64Helper().encodeToString(new Uint8Array(buffer));
          imageUrl = 'data:image/jpeg;base64,' + encoded;
        } catch (ignore) {
          imageError = true;
        }
      }
      if (token !== SkeletonDebugFeed.session()) {
        return;
      }
      const frame: SkeletonDebugFrame = { sequence: ++SkeletonDebugFeed.sequence, timestamp,
        width, height, people, points: visibleJoints(points, width, height), imageUrl, imageError };
      SkeletonDebugFeed.listener?.(frame, '');
    } catch (ignore) {
      // Debugging must never turn a successful inference into a detection failure.
      if (token === SkeletonDebugFeed.session()) {
        SkeletonDebugFeed.fail('骨骼画面暂不可用');
      }
    } finally {
      if (packer) {
        try {
          await packer.release();
        } catch (ignore) {
        }
      }
    }
  }
}
