import { faceDetector, skeletonDetection, visionBase } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { BusinessError } from '@ohos.base';
import {
  FaceFrame,
  Point2D,
  PostureSample,
  SkeletonFrame
} from '../models/PostureTypes';

function emptyPoint(): Point2D {
  return {
    x: 0,
    y: 0,
    score: 0
  };
}

function pointFromSkeleton(point: skeletonDetection.SkeletonPoint | undefined): Point2D | undefined {
  if (!point) {
    return undefined;
  }
  return {
    x: point.point.x,
    y: point.point.y,
    score: point.score
  };
}

export class CoreVisionPostureDetector {
  private skeletonDetector?: skeletonDetection.SkeletonDetector;
  private isFaceReady: boolean = false;
  private lastDetail: string = 'Core Vision 待检测';

  async prepare(): Promise<void> {
    if (!this.skeletonDetector) {
      this.skeletonDetector = await skeletonDetection.SkeletonDetector.create();
    }
    if (!this.isFaceReady) {
      this.isFaceReady = await faceDetector.init();
    }
  }

  async detect(pixelMap: image.PixelMap): Promise<PostureSample> {
    await this.prepare();
    const request: visionBase.Request = {
      inputData: { pixelMap }
    };

    let skeletonResponse: skeletonDetection.SkeletonDetectionResponse = {
      skeletons: []
    } as skeletonDetection.SkeletonDetectionResponse;
    let skeletonWarning = '';
    try {
      skeletonResponse = await this.skeletonDetector!.process(request);
    } catch (error) {
      skeletonWarning = '骨架检测降级：' + this.errorSummary(error as Error);
    }
    let faces: Array<faceDetector.Face>;
    try {
      faces = await faceDetector.detect({ pixelMap });
    } catch (error) {
      throw new Error('人脸检测失败：' + this.errorSummary(error as Error));
    }
    this.lastDetail = skeletonWarning.length > 0 ? skeletonWarning + ' · 人脸检测完成' : '骨架与人脸检测完成';

    return {
      timestamp: Date.now(),
      skeleton: this.toSkeletonFrame(skeletonResponse),
      face: this.toFaceFrame(faces)
    };
  }

  async release(): Promise<void> {
    if (this.skeletonDetector) {
      await this.skeletonDetector.destroy();
      this.skeletonDetector = undefined;
    }
    if (this.isFaceReady) {
      await faceDetector.release();
      this.isFaceReady = false;
    }
  }

  statusDetail(): string {
    return this.lastDetail;
  }

  private toSkeletonFrame(response: skeletonDetection.SkeletonDetectionResponse): SkeletonFrame {
    if (!response.skeletons || response.skeletons.length === 0) {
      return {};
    }
    const skeleton = response.skeletons[0];
    const nose = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.NOSE);
    const leftEar = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.LEFT_EAR);
    const rightEar = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.RIGHT_EAR);
    const leftShoulder = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.LEFT_SHOULDER);
    const rightShoulder = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.RIGHT_SHOULDER);
    const leftHip = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.LEFT_HIP);
    const rightHip = this.findPoint(skeleton.points, skeletonDetection.SkeletonPointType.RIGHT_HIP);
    return {
      nose,
      leftEar,
      rightEar,
      leftShoulder,
      rightShoulder,
      leftHip,
      rightHip
    };
  }

  private findPoint(
    points: Array<skeletonDetection.SkeletonPoint>,
    type: skeletonDetection.SkeletonPointType
  ): Point2D | undefined {
    const match = points.find((point: skeletonDetection.SkeletonPoint) => point.type === type);
    return pointFromSkeleton(match);
  }

  private toFaceFrame(faces: Array<faceDetector.Face>): FaceFrame {
    if (!faces || faces.length === 0) {
      return {
        yaw: 0,
        pitch: 0,
        roll: 0,
        mouthOpenRatio: 0.16,
        confidence: 0,
        rect: {
          left: 0,
          top: 0,
          width: 1,
          height: 1
        }
      };
    }
    const face = faces[0];
    return {
      yaw: face.pose.yaw,
      pitch: face.pose.pitch,
      roll: face.pose.roll,
      mouthOpenRatio: this.estimateMouthRatio(face),
      confidence: face.probability,
      rect: {
        left: face.rect.left,
        top: face.rect.top,
        width: face.rect.width,
        height: face.rect.height
      }
    };
  }

  private estimateMouthRatio(face: faceDetector.Face): number {
    if (!face.points || face.points.length < 2 || face.rect.height <= 0) {
      return 0.16;
    }
    const lowerHalfPoints = face.points.filter((point: faceDetector.FacePoint) =>
      point.y > face.rect.top + face.rect.height * 0.55);
    if (lowerHalfPoints.length < 2) {
      return 0.16;
    }
    let minY = lowerHalfPoints[0].y;
    let maxY = lowerHalfPoints[0].y;
    lowerHalfPoints.forEach((point: faceDetector.FacePoint) => {
      if (point.y < minY) {
        minY = point.y;
      }
      if (point.y > maxY) {
        maxY = point.y;
      }
    });
    const roughOpen = Math.abs(maxY - minY) / Math.max(face.rect.height, 1);
    if (roughOpen < 0.04) {
      return 0.16;
    }
    if (roughOpen > 0.7) {
      return 0.7;
    }
    return roughOpen;
  }

  private errorSummary(error: Error): string {
    let message = error.message;
    if (message === undefined || message.length === 0) {
      message = JSON.stringify(error);
    }
    try {
      const businessError = error as BusinessError;
      return 'code=' + businessError.code.toString() + ' ' + message;
    } catch (ignore) {
      return message;
    }
  }
}

export function createEmptyPostureSample(): PostureSample {
  return {
    timestamp: Date.now(),
    skeleton: {
      nose: emptyPoint(),
      leftShoulder: emptyPoint(),
      rightShoulder: emptyPoint()
    },
    face: {
      yaw: 0,
      pitch: 0,
      roll: 0,
      mouthOpenRatio: 0.16,
      confidence: 0,
      rect: {
        left: 0,
        top: 0,
        width: 1,
        height: 1
      }
    }
  };
}
