import { arEngine, arViewController } from '@kit.AREngine';

export function supportsFaceTracking(): boolean {
  try {
    return canIUse('SystemCapability.AREngine.Core') &&
      arViewController.isARTypeSupported(arEngine.ARFeatureType.ARENGINE_FEATURE_TYPE_FACE);
  } catch (_) {
    return false;
  }
}
