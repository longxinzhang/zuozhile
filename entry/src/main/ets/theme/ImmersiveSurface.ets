import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

export class ImmersiveSurface implements AttributeModifier<CommonAttribute> {
  applyNormalAttribute(instance: CommonAttribute): void {
    // Keep API 26 material creation and application out of the API 23 fallback path.
    if (deviceInfo.apiAvailable('26.0.0')) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        applyShadow: false,
        interactive: false
      }));
    }
  }
}
