import { common } from '@kit.AbilityKit';
import { camera } from '@kit.CameraKit';

export interface CameraProbeResult {
  available: boolean;
  cameraCount: number;
  hasFrontCamera: boolean;
  previewProfileCount: number;
  photoProfileCount: number;
  detail: string;
}

function positionLabel(position: camera.CameraPosition): string {
  if (position === camera.CameraPosition.CAMERA_POSITION_FRONT) {
    return 'front';
  }
  if (position === camera.CameraPosition.CAMERA_POSITION_BACK) {
    return 'back';
  }
  return 'unspecified';
}

export class CameraProbeService {
  static probe(context: common.UIAbilityContext): CameraProbeResult {
    try {
      const manager = camera.getCameraManager(context);
      const cameras = manager.getSupportedCameras();
      if (!cameras || cameras.length === 0) {
        return {
          available: false,
          cameraCount: 0,
          hasFrontCamera: false,
          previewProfileCount: 0,
          photoProfileCount: 0,
          detail: '未发现摄像头'
        };
      }

      const front = cameras.find((item: camera.CameraDevice) =>
        item.cameraPosition === camera.CameraPosition.CAMERA_POSITION_FRONT);
      const selected = front ? front : cameras[0];
      const modes = manager.getSupportedSceneModes(selected);
      const mode = modes.includes(camera.SceneMode.NORMAL_PHOTO) ? camera.SceneMode.NORMAL_PHOTO : modes[0];
      const capability = manager.getSupportedOutputCapability(selected, mode);
      const previewCount = capability.previewProfiles ? capability.previewProfiles.length : 0;
      const photoCount = capability.photoProfiles ? capability.photoProfiles.length : 0;

      return {
        available: previewCount > 0 || photoCount > 0,
        cameraCount: cameras.length,
        hasFrontCamera: !!front,
        previewProfileCount: previewCount,
        photoProfileCount: photoCount,
        detail: 'camera=' + selected.cameraId + ' ' + positionLabel(selected.cameraPosition) +
          ' mode=' + mode.toString() + ' preview=' + previewCount.toString() + ' photo=' + photoCount.toString()
      };
    } catch (error) {
      return {
        available: false,
        cameraCount: 0,
        hasFrontCamera: false,
        previewProfileCount: 0,
        photoProfileCount: 0,
        detail: '相机能力查询失败'
      };
    }
  }
}
