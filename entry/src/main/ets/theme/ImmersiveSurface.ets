import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';

export class ImmersiveSurface implements AttributeModifier<CommonAttribute> {
  private tint: ResourceColor;
  constructor(tint: ResourceColor = '#20FFFFFF') {
    this.tint = tint;
  }
  applyNormalAttribute(instance: CommonAttribute): void {
    // Keep API 26 material creation and application out of the API 23 fallback path.
    if (deviceInfo.apiAvailable('26.0.0')) {
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        materialColor: this.tint,
        applyShadow: true,
        interactive: true,
        lightEffect: {}
      }));
    }
  }
}

export class HarmonyTabBar implements AttributeModifier<TabsAttribute> {
  applyNormalAttribute(instance: TabsAttribute): void {
    if (deviceInfo.apiAvailable('26.0.0')) {
      instance.barOverlap(true).barFloatingStyle({
        barSideMargin: 20, barBottomMargin: 8, maskHeight: 24,
        adaptToHandedness: false,
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: uiMaterial.ImmersiveStyle.REGULAR, materialColor: '#18FFFFFF',
          interactive: true, lightEffect: {}
        })
      });
    } else {
      instance.barOverlap(false).barBackgroundColor('#F7F9FC');
    }
  }
}

export function navigationBottomInset(): number {
  return deviceInfo.apiAvailable('26.0.0') ? 96 : 24;
}

export function navigationTitleOptions(): NavigationTitleOptions {
  if (deviceInfo.apiAvailable('26.0.0')) {
    return {
      barStyle: BarStyle.STANDARD,
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: uiMaterial.ImmersiveStyle.REGULAR,
        materialColor: '#18FFFFFF', applyShadow: false, interactive: false
      })
    };
  }
  return { backgroundColor: '#F4F5F7', barStyle: BarStyle.STANDARD };
}
