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

function finiteOr(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
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
      try {
        this.skeletonDetector = await skeletonDetection.SkeletonDetector.create();
      } catch (error) {
        throw new Error('骨架检测初始化失败：' + this.errorSummary(error as Error));
      }
    }
    if (!this.isFaceReady) {
      try {
        this.isFaceReady = await faceDetector.init();
      } catch (error) {
        throw new Error('人脸检测初始化失败：' + this.errorSummary(error as Error));
      }
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
    const skeletonCount = skeletonResponse.skeletons ? skeletonResponse.skeletons.length : 0;
    const faceCount = faces ? faces.length : 0;
    const countDetail = '骨架 ' + skeletonCount.toString() + ' · 人脸 ' + faceCount.toString();
    this.lastDetail = skeletonWarning.length > 0 ?
      skeletonWarning + ' · 人脸检测完成 · ' + countDetail :
      '骨架与人脸检测完成 · ' + countDetail;

    return {
      timestamp: Date.now(),
      skeleton: this.toSkeletonFrame(skeletonResponse),
      face: this.toFaceFrame(faces)
    };
  }

  async release(): Promise<void> {
    let warning = '';
    if (this.skeletonDetector) {
      const detector = this.skeletonDetector;
      this.skeletonDetector = undefined;
      try {
        await detector.destroy();
      } catch (error) {
        warning = '骨架检测释放失败：' + this.errorSummary(error as Error);
      }
    }
    if (this.isFaceReady) {
      try {
        await faceDetector.release();
      } catch (error) {
        warning = warning.length > 0 ?
          warning + ' · 人脸检测释放失败：' + this.errorSummary(error as Error) :
          '人脸检测释放失败：' + this.errorSummary(error as Error);
      } finally {
        this.isFaceReady = false;
      }
    }
    this.lastDetail = warning.length > 0 ? warning : 'Core Vision 已释放';
  }

  private selectPrimarySkeleton(skeletons: Array<skeletonDetection.Skeleton>): skeletonDetection.Skeleton | undefined {
    if (!skeletons || skeletons.length === 0) {
      return undefined;
    }
    let selected = skeletons[0];
    let selectedScore = this.skeletonQuality(selected);
    skeletons.forEach((skeleton: skeletonDetection.Skeleton) => {
      const score = this.skeletonQuality(skeleton);
      if (score > selectedScore) {
        selected = skeleton;
        selectedScore = score;
      }
    });
    return selected;
  }

  private skeletonQuality(skeleton: skeletonDetection.Skeleton): number {
    const points = skeleton.points ? skeleton.points : [];
    const noseScore = this.rawSkeletonPointScore(points, skeletonDetection.SkeletonPointType.NOSE);
    const leftShoulderScore = this.rawSkeletonPointScore(points, skeletonDetection.SkeletonPointType.LEFT_SHOULDER);
    const rightShoulderScore = this.rawSkeletonPointScore(points, skeletonDetection.SkeletonPointType.RIGHT_SHOULDER);
    const leftHipScore = this.rawSkeletonPointScore(points, skeletonDetection.SkeletonPointType.LEFT_HIP);
    const rightHipScore = this.rawSkeletonPointScore(points, skeletonDetection.SkeletonPointType.RIGHT_HIP);
    const keyPointScore = noseScore * 2 + leftShoulderScore * 3 + rightShoulderScore * 3 +
      leftHipScore + rightHipScore;
    const boxArea = skeleton.boundingBox ?
      Math.max(skeleton.boundingBox.width * skeleton.boundingBox.height, 0) : 0;
    return finiteOr(skeleton.score, 0) * 100 + keyPointScore * 100 + Math.sqrt(boxArea);
  }

  private rawSkeletonPointScore(
    points: Array<skeletonDetection.SkeletonPoint>,
    type: skeletonDetection.SkeletonPointType
  ): number {
    const match = points.find((point: skeletonDetection.SkeletonPoint) => point.type === type);
    return match ? finiteOr(match.score, 0) : 0;
  }

  private selectPrimaryFace(faces: Array<faceDetector.Face>): faceDetector.Face | undefined {
    if (!faces || faces.length === 0) {
      return undefined;
    }
    let selected = faces[0];
    let selectedScore = this.faceQuality(selected);
    faces.forEach((face: faceDetector.Face) => {
      const score = this.faceQuality(face);
      if (score > selectedScore) {
        selected = face;
        selectedScore = score;
      }
    });
    return selected;
  }

  private faceQuality(face: faceDetector.Face): number {
    const area = face.rect ? Math.max(face.rect.width * face.rect.height, 0) : 0;
    const pointCount = face.points ? face.points.length : 0;
    const landmarkScore = Math.min(pointCount, 16) / 16;
    return finiteOr(face.probability, 0) * 10000 + Math.sqrt(area) + landmarkScore * 100;
  }

  private emptyFaceFrame(): FaceFrame {
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

  private safeFaceNumber(value: number): number {
    return finiteOr(value, 0);
  }

  private safeFaceRect(face: faceDetector.Face): FaceFrame {
    const rect = face.rect;
    return {
      yaw: this.safeFaceNumber(face.pose.yaw),
      pitch: this.safeFaceNumber(face.pose.pitch),
      roll: this.safeFaceNumber(face.pose.roll),
      mouthOpenRatio: this.estimateMouthRatio(face),
      confidence: this.safeFaceNumber(face.probability),
      rect: {
        left: this.safeFaceNumber(rect.left),
        top: this.safeFaceNumber(rect.top),
        width: Math.max(this.safeFaceNumber(rect.width), 1),
        height: Math.max(this.safeFaceNumber(rect.height), 1)
      }
    };
  }

  statusDetail(): string {
    return this.lastDetail;
  }

  private toSkeletonFrame(response: skeletonDetection.SkeletonDetectionResponse): SkeletonFrame {
    if (!response.skeletons || response.skeletons.length === 0) {
      return {};
    }
    const skeleton = this.selectPrimarySkeleton(response.skeletons);
    if (!skeleton) {
      return {};
    }
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
      return this.emptyFaceFrame();
    }
    const face = this.selectPrimaryFace(faces);
    return face ? this.safeFaceRect(face) : this.emptyFaceFrame();
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
