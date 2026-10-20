import { common } from '@kit.AbilityKit';
import { util } from '@kit.ArkTS';
import { display } from '@kit.ArkUI';
import { BusinessError, systemDateTime } from '@kit.BasicServicesKit';
import { camera } from '@kit.CameraKit';
import { skeletonDetection, visionBase } from '@kit.CoreVisionKit';
import { image } from '@kit.ImageKit';
import { DebugJoint, visibleJoints } from '../debug/SkeletonGeometry';
import { LiveSkeletonFrameSource } from '../models/LiveSkeletonMonitor';
import { SkeletonDebugFrame } from './SkeletonDebugFeed';

const NV21_IMAGE_FORMAT = 25;
const MAX_PREVIEW_EDGE = 1280;
const MAX_PREVIEW_PIXELS = 1280 * 720;
const FRAME_WAIT_MS = 5000;
const CANCELLATION_POLL_MS = 50;

interface PreviewFrame {
  buffer: ArrayBuffer;
  width: number;
  height: number;
  rotation: number;
  timestamp: number;
}

interface PreviewRequest {
  resolve: (frame: PreviewFrame | undefined) => void;
  isCurrent: () => boolean;
  deadline: number;
  timer: number;
}

export class LiveSkeletonCameraSource implements LiveSkeletonFrameSource {
  private context: common.UIAbilityContext;
  private device: camera.CameraDevice | undefined = undefined;
  private input: camera.CameraInput | undefined = undefined;
  private preview: camera.PreviewOutput | undefined = undefined;
  private session: camera.PhotoSession | undefined = undefined;
  private receiver: image.ImageReceiver | undefined = undefined;
  private detector: skeletonDetection.SkeletonDetector | undefined = undefined;
  private prepareTask: Promise<void> | undefined = undefined;
  private frameTask: Promise<SkeletonDebugFrame | undefined> | undefined = undefined;
  private readerTask: Promise<void> | undefined = undefined;
  private disposeTask: Promise<void> | undefined = undefined;
  private pending: PreviewRequest | undefined = undefined;
  private failure: Error | undefined = undefined;
  private releaseErrors: string[] = [];
  private unreleasedImages: image.Image[] = [];
  private unreleasedPixelMaps: image.PixelMap[] = [];
  private unreleasedPackers: image.ImagePacker[] = [];
  private ready: boolean = false;
  private disposed: boolean = false;
  private listening: boolean = false;
  private startAttempted: boolean = false;
  private arrivalPending: boolean = false;
  private previewWidth: number = 0;
  private previewHeight: number = 0;
  private sequence: number = 0;
  private lastReadError: string = '';
  private detail: string = '连续骨骼监看待启动';

  private cameraError: (error: BusinessError) => void = (error: BusinessError): void => {
    this.fail(new Error('Continuous camera preview failed: ' + error.code + ' ' + error.message));
  };

  private imageArrival: (error: BusinessError) => void = (error: BusinessError): void => {
    if (this.disposed) {
      return;
    }
    if (error) {
      this.cameraError(error);
      return;
    }
    this.arrivalPending = true;
    this.beginRead();
  };

  constructor(context: common.UIAbilityContext) {
    this.context = context;
  }

  statusDetail(): string {
    return this.detail;
  }

  async prepare(isCurrent: () => boolean): Promise<void> {
    if (!this.current(isCurrent) || this.ready) {
      return;
    }
    let task = this.prepareTask;
    if (task === undefined) {
      task = this.initialize(isCurrent);
      this.prepareTask = task;
    }
    try {
      await task;
    } catch (error) {
      const cancelled = !this.current(isCurrent);
      let message = '连续监看准备失败：' + String(error);
      try {
        await this.dispose();
      } catch (cleanupError) {
        message += '; ' + String(cleanupError);
      }
      if (!cancelled && isCurrent()) {
        this.detail = message;
        throw new Error(message);
      }
      return;
    }
    if (!this.current(isCurrent)) {
      await this.dispose();
    }
  }

  async nextFrame(includeImage: boolean,
    isCurrent: () => boolean): Promise<SkeletonDebugFrame | undefined> {
    if (!this.current(isCurrent)) {
      return undefined;
    }
    this.checkFailure();
    if (!this.ready) {
      throw new Error('Prepare the continuous skeleton preview before requesting frames');
    }
    if (this.frameTask !== undefined) {
      throw new Error('Only one skeleton frame request may run at a time');
    }
    const task = this.processNextFrame(includeImage, isCurrent);
    this.frameTask = task;
    try {
      const frame = await task;
      return this.current(isCurrent) ? frame : undefined;
    } catch (error) {
      if (!this.current(isCurrent)) {
        return undefined;
      }
      throw new Error(String(error));
    } finally {
      this.frameTask = undefined;
    }
  }

  dispose(): Promise<void> {
    const existing = this.disposeTask;
    if (existing !== undefined) {
      return existing;
    }
    this.disposed = true;
    this.ready = false;
    this.arrivalPending = false;
    const request = this.pending;
    if (request !== undefined) {
      this.complete(request, undefined);
    }
    const task = this.releaseSource().catch((error: Error): void => {
      this.disposeTask = undefined;
      throw new Error(error.message);
    });
    this.disposeTask = task;
    return task;
  }

  private current(isCurrent: () => boolean): boolean {
    return !this.disposed && isCurrent();
  }

  private async initialize(isCurrent: () => boolean): Promise<void> {
    try {
      if (!this.current(isCurrent)) {
        return;
      }
      if (!canIUse('SystemCapability.Multimedia.Camera.Core') ||
        !canIUse('SystemCapability.Multimedia.Image.ImageReceiver') ||
        !canIUse('SystemCapability.AI.Vision.SkeletonDetection')) {
        throw new Error('Camera, ImageReceiver and Core Vision skeleton detection capabilities are required');
      }
      this.detail = '正在准备前置相机连续预览';
      const manager = camera.getCameraManager(this.context);
      const device: camera.CameraDevice | undefined = manager.getCameraDevice(
        camera.CameraPosition.CAMERA_POSITION_FRONT, camera.CameraType.CAMERA_TYPE_DEFAULT);
      if (device === undefined || device.cameraPosition !== camera.CameraPosition.CAMERA_POSITION_FRONT) {
        throw new Error('No current default front camera is available');
      }
      if (!manager.getSupportedSceneModes(device).includes(camera.SceneMode.NORMAL_PHOTO)) {
        throw new Error('The front camera does not support a NORMAL_PHOTO preview session');
      }
      const capability = manager.getSupportedFullOutputCapability(device, camera.SceneMode.NORMAL_PHOTO);
      const profile = this.selectProfile(capability.previewProfiles);
      if (profile === undefined) {
        throw new Error('The front camera has no supported even-sized NV21 preview up to 1280x720 pixels');
      }
      this.previewWidth = profile.size.width;
      this.previewHeight = profile.size.height;
      const size: image.Size = { width: this.previewWidth, height: this.previewHeight };
      const options: image.ImageReceiverOptions = { size: size, capacity: 3 };
      const receiver = image.createImageReceiver(options);
      if (receiver === undefined) {
        throw new Error('ImageReceiver is unavailable on this platform');
      }
      this.receiver = receiver;
      const surfaceId = await receiver.getReceivingSurfaceId();
      if (!this.current(isCurrent)) {
        return;
      }
      this.checkFailure();
      if (surfaceId.length === 0) {
        throw new Error('ImageReceiver returned an empty preview surface');
      }
      this.device = device;
      const input = manager.createCameraInput(device);
      this.input = input;
      input.on('error', device, this.cameraError);
      await input.open();
      if (!this.current(isCurrent)) {
        return;
      }
      this.checkFailure();
      if (input.isPhysicalCameraOrientationVariable()) {
        input.usePhysicalCameraOrientation(true);
      }
      const preview = manager.createPreviewOutput(profile, surfaceId);
      this.preview = preview;
      preview.on('error', this.cameraError);
      const session = manager.createSession<camera.PhotoSession>(camera.SceneMode.NORMAL_PHOTO);
      this.session = session;
      session.on('error', this.cameraError);
      session.beginConfig();
      if (!session.canAddInput(input)) {
        throw new Error('The front camera input cannot be added to the preview session');
      }
      session.addInput(input);
      if (!session.canAddOutput(preview)) {
        throw new Error('The ImageReceiver preview cannot be added to the camera session');
      }
      session.addOutput(preview);
      if (preview.isBandwidthCompressionSupported()) {
        preview.enableBandwidthCompression(false);
      }
      await session.commitConfig();
      if (!this.current(isCurrent)) {
        return;
      }
      this.checkFailure();
      this.currentRotation();
      this.detector = await skeletonDetection.SkeletonDetector.create();
      if (!this.current(isCurrent)) {
        return;
      }
      this.checkFailure();
      if (this.detector === undefined) {
        throw new Error('The skeleton detector could not be created');
      }
      receiver.on('imageArrival', this.imageArrival);
      this.listening = true;
      this.startAttempted = true;
      await session.start();
      if (!this.current(isCurrent)) {
        return;
      }
      this.checkFailure();
      this.ready = true;
      this.detail = '前置连续预览 · ' + this.previewWidth + ' × ' + this.previewHeight +
        ' · 仅骨骼检测 · 忙时丢旧帧';
    } catch (error) {
      throw new Error(String(error));
    }
  }

  private selectProfile(profiles: camera.Profile[]): camera.Profile | undefined {
    let selected: camera.Profile | undefined = undefined;
    let distance = Number.POSITIVE_INFINITY;
    for (const profile of profiles) {
      const width = profile.size.width;
      const height = profile.size.height;
      if (profile.format !== camera.CameraFormat.CAMERA_FORMAT_YUV_420_SP ||
        !Number.isInteger(width) || !Number.isInteger(height) || width < 128 || height < 128 ||
        width % 2 !== 0 || height % 2 !== 0 || Math.max(width, height) > MAX_PREVIEW_EDGE ||
        width * height > MAX_PREVIEW_PIXELS) {
        continue;
      }
      const candidateDistance = Math.abs(width * height - 640 * 480);
      if (candidateDistance < distance) {
        selected = profile;
        distance = candidateDistance;
      }
    }
    return selected;
  }

  private currentRotation(): number {
    try {
      const preview = this.preview;
      if (preview === undefined) {
        throw new Error('The camera preview is unavailable for rotation');
      }
      const displayRotation = display.getDefaultDisplaySync().rotation * 90;
      const rotation: camera.ImageRotation | undefined = preview.getPreviewRotation(displayRotation);
      if (rotation === undefined || !Number.isFinite(rotation) || rotation % 90 !== 0) {
        throw new Error('The front camera returned an invalid preview rotation');
      }
      return (rotation + (displayRotation === 90 || displayRotation === 270 ? 180 : 0)) % 360;
    } catch (error) {
      throw new Error('Unable to determine the live front-camera rotation: ' + String(error));
    }
  }

  private waitForFrame(isCurrent: () => boolean): Promise<PreviewFrame | undefined> {
    return new Promise<PreviewFrame | undefined>((resolve: (frame: PreviewFrame | undefined) => void): void => {
      if (!this.current(isCurrent)) {
        resolve(undefined);
        return;
      }
      const request: PreviewRequest = {
        resolve: resolve, isCurrent: isCurrent, deadline: this.now() + FRAME_WAIT_MS, timer: -1
      };
      this.pending = request;
      this.beginRead();
      request.timer = setInterval((): void => {
        if (!this.current(request.isCurrent)) {
          this.complete(request, undefined);
        } else if (this.now() >= request.deadline) {
          this.fail(new Error('Timed out waiting for a live preview frame' +
            (this.lastReadError.length > 0 ? ': ' + this.lastReadError : '')));
        }
      }, CANCELLATION_POLL_MS);
    });
  }

  private complete(request: PreviewRequest, frame: PreviewFrame | undefined): void {
    if (this.pending !== request) {
      return;
    }
    this.pending = undefined;
    clearInterval(request.timer);
    request.resolve(frame);
  }

  private fail(error: Error): void {
    if (this.disposed) {
      return;
    }
    if (this.failure === undefined) {
      this.failure = error;
      this.detail = error.message;
    }
    const request = this.pending;
    if (request !== undefined) {
      this.complete(request, undefined);
    }
  }

  private checkFailure(): void {
    const failure = this.failure;
    if (failure !== undefined) {
      throw failure;
    }
  }

  private beginRead(): void {
    const receiver = this.receiver;
    if (this.disposed || this.failure !== undefined || !this.arrivalPending ||
      this.readerTask !== undefined || receiver === undefined) {
      return;
    }
    this.readerTask = Promise.resolve<void>(undefined).then<void>(async (): Promise<void> => {
      try {
        while (this.arrivalPending && !this.disposed && this.failure === undefined) {
          this.arrivalPending = false;
          await this.readImage(receiver);
        }
      } finally {
        this.readerTask = undefined;
      }
    });
  }

  private async readImage(receiver: image.ImageReceiver): Promise<void> {
    let raw: image.Image | undefined = undefined;
    let frame: PreviewFrame | undefined = undefined;
    let request: PreviewRequest | undefined = undefined;
    try {
      try {
        raw = await receiver.readLatestImage();
        this.lastReadError = '';
      } catch (error) {
        this.lastReadError = String(error);
        return;
      }
      request = this.pending;
      if (raw === undefined || request === undefined || !this.current(request.isCurrent)) {
        return;
      }
      const timestamp = Date.now();
      const rotation = this.currentRotation();
      const component = await raw.getComponent(image.ComponentType.JPEG);
      if (this.pending !== request || !this.current(request.isCurrent)) {
        return;
      }
      frame = this.copyFrame(raw, component, rotation, timestamp);
    } catch (error) {
      if (request !== undefined && this.pending === request && this.current(request.isCurrent)) {
        this.fail(new Error('Unsupported or invalid live preview frame: ' + String(error)));
      }
    } finally {
      if (raw !== undefined) {
        try {
          await raw.release();
        } catch (error) {
          this.unreleasedImages.push(raw);
          this.recordReleaseError('Image.release', String(error));
        }
      }
      if (request !== undefined && frame !== undefined && this.failure === undefined &&
        this.current(request.isCurrent)) {
        this.complete(request, frame);
      }
    }
  }

  private copyFrame(raw: image.Image, component: image.Component, rotation: number,
    timestamp: number): PreviewFrame {
    const width = raw.size.width;
    const height = raw.size.height;
    const stride = component.rowStride;
    if (raw.format !== NV21_IMAGE_FORMAT || width !== this.previewWidth || height !== this.previewHeight) {
      throw new Error('Expected the configured NV21 image (format 25), received format ' + raw.format +
        ' at ' + width + 'x' + height);
    }
    const rows = height + height / 2;
    if (!Number.isInteger(stride) || stride < width || stride % 2 !== 0 ||
      !component.byteBuffer || component.byteBuffer.byteLength < stride * rows) {
      throw new Error('Expected enough bytes for packed Y + VU planes with equal row strides; stride=' +
        stride + ', pixelStride=' + component.pixelStride + ', bytes=' + component.byteBuffer?.byteLength);
    }
    const buffer = new ArrayBuffer(width * rows);
    const packed = new Uint8Array(buffer);
    if (stride === width) {
      packed.set(new Uint8Array(component.byteBuffer, 0, width * rows));
    } else {
      for (let row = 0; row < rows; row++) {
        packed.set(new Uint8Array(component.byteBuffer, row * stride, width), row * width);
      }
    }
    const frame: PreviewFrame = {
      buffer: buffer, width: width, height: height, rotation: rotation, timestamp: timestamp
    };
    return frame;
  }

  private async processNextFrame(includeImage: boolean,
    isCurrent: () => boolean): Promise<SkeletonDebugFrame | undefined> {
    const captured = await this.waitForFrame(isCurrent);
    if (!this.current(isCurrent)) {
      return undefined;
    }
    this.checkFailure();
    if (captured === undefined) {
      return undefined;
    }
    let pixelMap: image.PixelMap | undefined = undefined;
    let packer: image.ImagePacker | undefined = undefined;
    let frame: SkeletonDebugFrame | undefined = undefined;
    try {
      const size: image.Size = { width: captured.width, height: captured.height };
      const options: image.InitializationOptions = {
        size: size, srcPixelFormat: image.PixelMapFormat.NV21,
        pixelFormat: image.PixelMapFormat.RGBA_8888, editable: true
      };
      pixelMap = await image.createPixelMap(captured.buffer, options);
      if (!this.current(isCurrent)) {
        return undefined;
      }
      await pixelMap.rotate(captured.rotation);
      if (!this.current(isCurrent)) {
        return undefined;
      }
      const info = pixelMap.getImageInfoSync();
      const width = info.size.width;
      const height = info.size.height;
      const swapsAxes = captured.rotation === 90 || captured.rotation === 270;
      if (width !== (swapsAxes ? captured.height : captured.width) ||
        height !== (swapsAxes ? captured.width : captured.height) ||
        info.pixelFormat !== image.PixelMapFormat.RGBA_8888) {
        throw new Error('NV21 conversion or rotation did not produce the expected RGBA geometry');
      }
      const detector = this.detector;
      if (detector === undefined) {
        throw new Error('The skeleton detector is unavailable');
      }
      const inputData: visionBase.ImageData = { pixelMap: pixelMap };
      const request: visionBase.Request = { inputData: inputData };
      const response = await detector.process(request);
      if (!this.current(isCurrent)) {
        return undefined;
      }
      this.checkFailure();
      const skeletons = response.skeletons;
      const points = this.selectPoints(skeletons, width, height);
      let imageUrl = '';
      let imageError = false;
      if (includeImage) {
        try {
          packer = image.createImagePacker();
          const packingOptions: image.PackingOption = { format: 'image/jpeg', quality: 75 };
          const buffer = await packer.packToData(pixelMap, packingOptions);
          if (!this.current(isCurrent)) {
            return undefined;
          }
          const encoded = await new util.Base64Helper().encodeToString(new Uint8Array(buffer));
          if (!this.current(isCurrent)) {
            return undefined;
          }
          imageUrl = 'data:image/jpeg;base64,' + encoded;
        } catch (error) {
          if (!this.current(isCurrent)) {
            return undefined;
          }
          imageError = true;
        }
      }
      frame = {
        sequence: 0, timestamp: captured.timestamp, width: width, height: height,
        people: skeletons.length, points: points, imageUrl: imageUrl, imageError: imageError
      };
    } catch (error) {
      if (!this.current(isCurrent)) {
        return undefined;
      }
      const failure = new Error('实时骨骼检测失败：' + String(error));
      this.fail(failure);
      throw failure;
    } finally {
      if (packer !== undefined) {
        try {
          await packer.release();
        } catch (error) {
          this.unreleasedPackers.push(packer);
          this.recordReleaseError('ImagePacker.release', String(error));
        }
      }
      if (pixelMap !== undefined) {
        try {
          await pixelMap.release();
        } catch (error) {
          this.unreleasedPixelMaps.push(pixelMap);
          this.recordReleaseError('PixelMap.release', String(error));
        }
      }
    }
    if (!this.current(isCurrent)) {
      return undefined;
    }
    this.checkFailure();
    if (frame !== undefined) {
      frame.sequence = ++this.sequence;
      this.detail = '前置连续检测 · ' + frame.people + ' 人 · ' + frame.points.length + '/17 关键点 · ' +
        frame.width + ' × ' + frame.height + ' · 忙时丢旧帧' +
        (frame.imageError ? ' · 相机画面编码暂不可用' : '');
    }
    return frame;
  }

  private selectPoints(skeletons: skeletonDetection.Skeleton[], width: number, height: number): DebugJoint[] {
    let selected: DebugJoint[] = [];
    let bestScore = -1;
    let bestJointScore = -1;
    for (const skeleton of skeletons) {
      const candidates: DebugJoint[] = [];
      for (const point of skeleton.points) {
        if (point.point) {
          const joint: DebugJoint = {
            type: point.type, x: point.point.x, y: point.point.y, confidence: point.score
          };
          candidates.push(joint);
        }
      }
      const points = visibleJoints(candidates, width, height);
      const score = Number.isFinite(skeleton.score) && skeleton.score >= 0 && skeleton.score <= 1 ?
        skeleton.score : -1;
      let jointScore = 0;
      for (const point of points) {
        jointScore += point.confidence;
      }
      if (score > bestScore || (score === bestScore && jointScore > bestJointScore)) {
        selected = points;
        bestScore = score;
        bestJointScore = jointScore;
      }
    }
    return selected;
  }

  private recordReleaseError(label: string, message: string): void {
    const detail = label + ': ' + message;
    this.releaseErrors.push(detail);
    this.fail(new Error(detail));
  }

  private async releaseSource(): Promise<void> {
    this.releaseErrors = [];
    const preparation = this.prepareTask;
    if (preparation !== undefined) {
      try {
        await preparation;
      } catch (error) {
      }
    }
    const receiver = this.receiver;
    if (receiver !== undefined && this.listening) {
      this.listening = false;
      try {
        receiver.off('imageArrival', this.imageArrival);
      } catch (error) {
        this.recordReleaseError('ImageReceiver.off', String(error));
      }
    }
    const session = this.session;
    if (session !== undefined && this.startAttempted) {
      try {
        await session.stop();
        this.startAttempted = false;
      } catch (error) {
        this.recordReleaseError('Session.stop', String(error));
      }
    }
    const reading = this.readerTask;
    if (reading !== undefined) {
      try {
        await reading;
      } catch (error) {
      }
    }
    if (session !== undefined) {
      try {
        session.off('error', this.cameraError);
      } catch (error) {
        this.recordReleaseError('Session.off', String(error));
      }
      try {
        await session.release();
        this.session = undefined;
        this.startAttempted = false;
      } catch (error) {
        this.recordReleaseError('Session.release', String(error));
      }
    }
    const preview = this.preview;
    if (preview !== undefined) {
      try {
        preview.off('error', this.cameraError);
      } catch (error) {
        this.recordReleaseError('PreviewOutput.off', String(error));
      }
      try {
        await preview.release();
        this.preview = undefined;
      } catch (error) {
        this.recordReleaseError('PreviewOutput.release', String(error));
      }
    }
    const input = this.input;
    const device = this.device;
    if (input !== undefined) {
      if (device !== undefined) {
        try {
          input.off('error', device, this.cameraError);
        } catch (error) {
          this.recordReleaseError('CameraInput.off', String(error));
        }
      }
      try {
        await input.close();
        this.input = undefined;
        this.device = undefined;
      } catch (error) {
        this.recordReleaseError('CameraInput.close', String(error));
      }
    }
    if (receiver !== undefined) {
      try {
        await receiver.release();
        this.receiver = undefined;
      } catch (error) {
        this.recordReleaseError('ImageReceiver.release', String(error));
      }
    }
    const processing = this.frameTask;
    if (processing !== undefined) {
      try {
        await processing;
      } catch (error) {
      }
    }
    const detector = this.detector;
    if (detector !== undefined) {
      try {
        await detector.destroy();
        this.detector = undefined;
      } catch (error) {
        this.recordReleaseError('SkeletonDetector.destroy', String(error));
      }
    }
    const images = this.unreleasedImages;
    this.unreleasedImages = [];
    for (const raw of images) {
      try {
        await raw.release();
      } catch (error) {
        this.unreleasedImages.push(raw);
        this.recordReleaseError('Image.release', String(error));
      }
    }
    const packers = this.unreleasedPackers;
    this.unreleasedPackers = [];
    for (const packer of packers) {
      try {
        await packer.release();
      } catch (error) {
        this.unreleasedPackers.push(packer);
        this.recordReleaseError('ImagePacker.release', String(error));
      }
    }
    const pixelMaps = this.unreleasedPixelMaps;
    this.unreleasedPixelMaps = [];
    for (const pixelMap of pixelMaps) {
      try {
        await pixelMap.release();
      } catch (error) {
        this.unreleasedPixelMaps.push(pixelMap);
        this.recordReleaseError('PixelMap.release', String(error));
      }
    }
    this.detail = this.releaseErrors.length > 0 ? '连续预览释放失败：' +
      this.releaseErrors.join('; ') : '连续骨骼监看已释放';
    if (this.releaseErrors.length > 0) {
      throw new Error(this.detail);
    }
  }

  private now(): number {
    return systemDateTime.getUptime(systemDateTime.TimeType.STARTUP, false);
  }
}
