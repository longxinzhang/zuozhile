import { common } from '@kit.AbilityKit';
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import * as nativeAR from 'libposture_ar.so';
import { CalibrationProfile, PostureSample } from '../models/PostureTypes';
import { CoreVisionPostureDetector } from './CoreVisionPostureDetector';
import { CoreVisionPostureSource } from './CoreVisionPostureSource';
import { PostureSource, PostureSourceKind, PostureSourceStatus } from './PostureSource';

export class ARPostureSource implements PostureSource {
  private context: common.UIAbilityContext;
  private fallback: CoreVisionPostureSource;
  private detector: CoreVisionPostureDetector = new CoreVisionPostureDetector();
  private started: boolean = false;
  private sampled: boolean = false;
  private usingFallback: boolean = false;
  private rotation: number = 0;
  private detail: string = '原生张口检测待启动';

  constructor(context: common.UIAbilityContext, surfaceId: string) {
    this.context = context;
    this.fallback = new CoreVisionPostureSource(context, surfaceId);
  }

  status(): PostureSourceStatus {
    return { kind: PostureSourceKind.CORE_VISION, label: '真实相机检测', isLive: true,
      detail: this.usingFallback ? this.detail + ' · ' + this.fallback.status().detail : this.detail };
  }

  async sample(profile: CalibrationProfile): Promise<PostureSample> {
    if (this.usingFallback) {
      return this.fallback.sample(profile);
    }
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      if (!this.started) {
        const devices = camera.getCameraManager(this.context).getSupportedCameras();
        const front = devices.find((device: camera.CameraDevice) =>
          device.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT);
        if (!front) {
          throw new Error('未发现前置摄像头');
        }
        this.rotation = front.cameraOrientation;
        nativeAR.start(this.context);
        this.started = true;
        await this.detector.prepare();
      }
      const frame = await nativeAR.capture();
      pixelMap = await image.createPixelMap(frame.rgba, {
        size: { width: frame.width, height: frame.height },
        pixelFormat: image.PixelMapFormat.RGBA_8888, editable: true
      });
      await pixelMap.rotate(this.rotation);
      const sample = await this.detector.detect(pixelMap);
      // Both detectors consume the same camera frame. Ambiguous faces never contribute a mouth score.
      sample.face.jawOpen = frame.jawOpen;
      sample.face.lipGapRatio = frame.lipGapRatio;
      sample.face.mouthAvailable = frame.faceCount === 1 && this.detector.faceCount() === 1 &&
        frame.jawOpen >= 0 && frame.jawOpen <= 1 && sample.face.confidence >= 0.8 &&
        frame.lipGapRatio >= 0 && frame.lipGapRatio <= 1 &&
        Math.abs(sample.face.yaw) <= 35 && Math.abs(sample.face.pitch) <= 30;
      sample.face.mouthStatus = sample.face.mouthAvailable ? '原生张口检测' :
        (frame.faceCount > 1 || this.detector.faceCount() > 1 ? '多人入镜，嘴部暂停计分' : '嘴部暂未可靠识别');
      this.sampled = true;
      this.detail = 'AR 同帧检测 · ' + frame.width + 'x' + frame.height + ' rotate=' + this.rotation +
        ' · jaw=' + frame.jawOpen.toFixed(3) + ' · lip=' + frame.lipGapRatio.toFixed(4) + ' · faces=' + frame.faceCount +
        ' · mouth=' + sample.face.mouthAvailable +
        ' · ' + this.detector.statusDetail();
      hilog.info(0, 'ZuozhileMouth', '%{public}s', this.detail);
      return sample;
    } catch (error) {
      // Never change camera geometry halfway through a calibration/session.
      if (this.sampled) {
        throw new Error((error as Error).message);
      }
      await this.releaseAR();
      this.usingFallback = true;
      this.detail = '原生张口暂不可用：' + (error as Error).message;
      hilog.warn(0, 'ZuozhileMouth', '%{public}s', this.detail);
      return this.fallback.sample(profile);
    } finally {
      if (pixelMap) {
        await pixelMap.release();
      }
    }
  }

  async dispose(): Promise<void> {
    await this.releaseAR();
    await this.fallback.dispose();
    this.sampled = false;
    this.usingFallback = false;
  }

  private async releaseAR(): Promise<void> {
    if (this.started) {
      nativeAR.stop();
      this.started = false;
    }
    await this.detector.release();
  }
}
