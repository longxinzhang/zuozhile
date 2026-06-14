import { common } from '@kit.AbilityKit';
import { camera } from '@kit.CameraKit';
import { image } from '@kit.ImageKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { BusinessError } from '@ohos.base';
import { CalibrationProfile, PostureSample } from '../models/PostureTypes';
import { CoreVisionPostureDetector } from './CoreVisionPostureDetector';
import { PostureSource, PostureSourceKind, PostureSourceStatus } from './PostureSource';

const MAX_DECODE_EDGE = 720;
const CAPTURE_TIMEOUT_MS = 6000;
const DOMAIN = 0x0000;
const TAG = 'ZuozhileCamera';

type PhotoCallback = (err: BusinessError, photo: camera.Photo) => void;
type PhotoResolver = (photo: camera.Photo) => void;
type PhotoRejecter = (error: Error) => void;

function pixelCount(profile: camera.Profile): number {
  return profile.size.width * profile.size.height;
}

function errorSummary(error: Error): string {
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

export class CoreVisionPostureSource implements PostureSource {
  private context: common.UIAbilityContext;
  private previewSurfaceId: string;
  private cameraInput?: camera.CameraInput;
  private previewOutput?: camera.PreviewOutput;
  private photoOutput?: camera.PhotoOutput;
  private session?: camera.PhotoSession;
  private detector: CoreVisionPostureDetector = new CoreVisionPostureDetector();
  private isReady: boolean = false;
  private isCapturing: boolean = false;
  private captureTimer: number = -1;
  private pendingResolve?: PhotoResolver;
  private pendingReject?: PhotoRejecter;
  private lastDetail: string = '真实相机待启动';
  private photoCallback: PhotoCallback = (err: BusinessError, photo: camera.Photo): void => {
    if (err) {
      this.rejectPending('拍照回调失败：' + errorSummary(err));
      return;
    }
    this.markStage('已收到照片回调');
    const resolve = this.pendingResolve;
    this.clearPending();
    if (resolve) {
      resolve(photo);
    } else if (photo) {
      this.ignoreAsyncFailure(async () => {
        await photo.release();
      });
    }
  };

  constructor(context: common.UIAbilityContext, previewSurfaceId: string) {
    this.context = context;
    this.previewSurfaceId = previewSurfaceId;
  }

  status(): PostureSourceStatus {
    return {
      kind: PostureSourceKind.CORE_VISION,
      label: '真实相机检测',
      detail: this.lastDetail,
      isLive: true
    };
  }

  async sample(profile: CalibrationProfile): Promise<PostureSample> {
    this.markStage('准备真实相机');
    await this.ensureReady();
    let photo: camera.Photo | undefined = undefined;
    let pixelMap: image.PixelMap | undefined = undefined;
    try {
      this.markStage('请求拍照抽帧');
      photo = await this.capturePhoto();
      this.markStage('照片已返回，准备解码');
      pixelMap = await this.photoToPixelMap(photo);
      this.markStage('PixelMap 已生成，提交 Core Vision');
      const sample = await this.detector.detect(pixelMap);
      this.markStage('Core Vision 已完成一次本机检测 · ' + this.detector.statusDetail());
      return sample;
    } catch (error) {
      throw this.failStage(this.lastDetail, error as Error);
    } finally {
      if (pixelMap) {
        await this.ignoreAsyncFailure(async () => {
          await pixelMap!.release();
        });
      }
      if (photo) {
        await this.ignoreAsyncFailure(async () => {
          await photo!.release();
        });
      }
    }
  }

  async dispose(): Promise<void> {
    this.rejectPending('相机已释放');
    if (this.photoOutput) {
      try {
        this.photoOutput.off('photoAvailable', this.photoCallback);
      } catch (error) {
      }
    }
    if (this.session) {
      await this.ignoreAsyncFailure(async () => {
        await this.session!.stop();
      });
      await this.ignoreAsyncFailure(async () => {
        await this.session!.release();
      });
      this.session = undefined;
    }
    if (this.previewOutput) {
      await this.ignoreAsyncFailure(async () => {
        await this.previewOutput!.release();
      });
      this.previewOutput = undefined;
    }
    if (this.photoOutput) {
      await this.ignoreAsyncFailure(async () => {
        await this.photoOutput!.release();
      });
      this.photoOutput = undefined;
    }
    if (this.cameraInput) {
      await this.ignoreAsyncFailure(async () => {
        await this.cameraInput!.close();
      });
      this.cameraInput = undefined;
    }
    await this.detector.release();
    this.isReady = false;
    this.lastDetail = '真实相机已释放';
  }

  private async ensureReady(): Promise<void> {
    if (this.isReady) {
      return;
    }
    try {
      this.markStage('查询相机管理器');
      const manager = camera.getCameraManager(this.context);
      const cameras = manager.getSupportedCameras();
      if (!cameras || cameras.length === 0) {
        throw new Error('未发现摄像头');
      }
      this.markStage('发现摄像头 ' + cameras.length.toString() + ' 个');
      const cameraDevice = this.selectCamera(cameras);
      const modes = manager.getSupportedSceneModes(cameraDevice);
      if (!modes || modes.length === 0) {
        throw new Error('未发现相机场景模式');
      }
      const mode = modes.includes(camera.SceneMode.NORMAL_PHOTO) ? camera.SceneMode.NORMAL_PHOTO : modes[0];
      this.markStage('选择相机 ' + cameraDevice.cameraId + ' · mode=' + mode.toString());
      const capability = manager.getSupportedOutputCapability(cameraDevice, mode);
      const previewProfile = this.selectPreviewProfile(capability.previewProfiles);
      const profile = this.selectPhotoProfile(capability.photoProfiles);
      if (!previewProfile) {
        throw new Error('未发现预览输出能力');
      }
      if (!profile) {
        throw new Error('未发现拍照输出能力');
      }
      if (this.previewSurfaceId.length === 0) {
        throw new Error('预览 surface 未就绪');
      }
      this.markStage('选择预览输出 ' + previewProfile.size.width.toString() + 'x' +
        previewProfile.size.height.toString() + ' format=' + previewProfile.format.toString());
      this.markStage('选择照片输出 ' + profile.size.width.toString() + 'x' +
        profile.size.height.toString() + ' format=' + profile.format.toString());

      this.cameraInput = manager.createCameraInput(cameraDevice);
      this.markStage('打开相机输入');
      await this.cameraInput.open();
      this.markStage('创建预览输出');
      this.previewOutput = manager.createPreviewOutput(previewProfile, this.previewSurfaceId);
      this.markStage('创建照片输出');
      this.photoOutput = manager.createPhotoOutput(profile);
      this.photoOutput.on('photoAvailable', this.photoCallback);
      this.markStage('创建拍照会话');
      this.session = manager.createSession<camera.PhotoSession>(mode);
      this.session.beginConfig();
      if (!this.session.canAddInput(this.cameraInput)) {
        throw new Error('相机输入无法加入会话');
      }
      this.markStage('加入相机输入');
      this.session.addInput(this.cameraInput);
      if (!this.session.canAddOutput(this.previewOutput)) {
        throw new Error('预览输出无法加入会话');
      }
      this.markStage('加入预览输出');
      this.session.addOutput(this.previewOutput);
      if (!this.session.canAddOutput(this.photoOutput)) {
        throw new Error('拍照输出无法加入会话');
      }
      this.markStage('加入拍照输出');
      this.session.addOutput(this.photoOutput);
      this.markStage('提交相机会话配置');
      await this.session.commitConfig();
      this.markStage('启动相机会话');
      await this.session.start();
      this.markStage('初始化 Core Vision');
      await this.detector.prepare();
      this.isReady = true;
      this.markStage('前置相机已启动 · ' + profile.size.width.toString() + 'x' +
        profile.size.height.toString());
    } catch (error) {
      const stage = this.lastDetail;
      await this.dispose();
      throw this.failStage(stage, error as Error);
    }
  }

  private selectCamera(cameras: Array<camera.CameraDevice>): camera.CameraDevice {
    const front = cameras.find((item: camera.CameraDevice) =>
      item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT);
    return front ? front : cameras[0];
  }

  private selectPhotoProfile(profiles: Array<camera.Profile>): camera.Profile | undefined {
    if (!profiles || profiles.length === 0) {
      return undefined;
    }
    const jpegProfiles = profiles.filter((profile: camera.Profile) =>
      profile.format === camera.CameraFormat.CAMERA_FORMAT_JPEG);
    const candidates = jpegProfiles.length > 0 ? jpegProfiles : profiles;
    let selected = candidates[0];
    candidates.forEach((profile: camera.Profile) => {
      if (pixelCount(profile) < pixelCount(selected)) {
        selected = profile;
      }
    });
    return selected;
  }

  private selectPreviewProfile(profiles: Array<camera.Profile>): camera.Profile | undefined {
    if (!profiles || profiles.length === 0) {
      return undefined;
    }
    let selected = profiles[0];
    profiles.forEach((profile: camera.Profile) => {
      if (pixelCount(profile) < pixelCount(selected)) {
        selected = profile;
      }
    });
    return selected;
  }

  private async capturePhoto(): Promise<camera.Photo> {
    if (!this.photoOutput) {
      throw new Error('拍照输出未初始化');
    }
    if (this.isCapturing) {
      throw new Error('上一帧仍在采样');
    }
    this.isCapturing = true;
    const waitPhoto = new Promise<camera.Photo>((resolve: PhotoResolver, reject: PhotoRejecter) => {
      this.pendingResolve = resolve;
      this.pendingReject = reject;
      this.captureTimer = setTimeout(() => {
        this.rejectPending('拍照超时');
      }, CAPTURE_TIMEOUT_MS);
    });
    try {
      this.markStage('调用 PhotoOutput.capture');
      await this.photoOutput.capture();
    } catch (error) {
      this.rejectPending('拍照请求失败');
      throw new Error(errorSummary(error as Error));
    }
    this.markStage('等待 photoAvailable 回调');
    return await waitPhoto;
  }

  private async photoToPixelMap(photo: camera.Photo): Promise<image.PixelMap> {
    const main = photo.main;
    let source: image.ImageSource | undefined = undefined;
    try {
      this.markStage('读取主图 JPEG · image=' + main.size.width.toString() + 'x' +
        main.size.height.toString() + ' format=' + main.format.toString());
      const component = await main.getComponent(image.ComponentType.JPEG);
      this.markStage('JPEG 已读取 · bytes=' + component.byteBuffer.byteLength.toString());
      source = image.createImageSource(component.byteBuffer);
      const sourceInfo = source.getImageInfoSync();
      const targetSize = this.targetSize(sourceInfo.size);
      this.markStage('创建 ImageSource · source=' + sourceInfo.size.width.toString() + 'x' +
        sourceInfo.size.height.toString() + ' target=' + targetSize.width.toString() + 'x' +
        targetSize.height.toString());
      const pixelMap = await source.createPixelMap({
        desiredSize: targetSize,
        desiredPixelFormat: image.PixelMapFormat.RGBA_8888
      });
      this.markStage('创建 PixelMap · target=' + targetSize.width.toString() + 'x' +
        targetSize.height.toString());
      return pixelMap;
    } finally {
      if (source) {
        await this.ignoreAsyncFailure(async () => {
          await source!.release();
        });
      }
      await this.ignoreAsyncFailure(async () => {
        await main.release();
      });
    }
  }

  private targetSize(size: image.Size): image.Size {
    const maxEdge = Math.max(size.width, size.height);
    if (maxEdge <= MAX_DECODE_EDGE) {
      return {
        width: size.width,
        height: size.height
      };
    }
    const ratio = MAX_DECODE_EDGE / maxEdge;
    return {
      width: Math.max(1, Math.round(size.width * ratio)),
      height: Math.max(1, Math.round(size.height * ratio))
    };
  }

  private clearPending(): void {
    if (this.captureTimer >= 0) {
      clearTimeout(this.captureTimer);
      this.captureTimer = -1;
    }
    this.pendingResolve = undefined;
    this.pendingReject = undefined;
    this.isCapturing = false;
  }

  private rejectPending(message: string): void {
    const reject = this.pendingReject;
    this.clearPending();
    if (reject) {
      reject(new Error(message));
    }
  }

  private markStage(message: string): void {
    this.lastDetail = message;
    hilog.info(DOMAIN, TAG, '%{public}s', message);
  }

  private failStage(stage: string, error: Error): Error {
    const detail = stage + '失败：' + errorSummary(error);
    this.lastDetail = detail;
    hilog.error(DOMAIN, TAG, '%{public}s', detail);
    return new Error(detail);
  }

  private async ignoreAsyncFailure(task: () => Promise<void>): Promise<void> {
    try {
      await task();
    } catch (error) {
    }
  }
}
