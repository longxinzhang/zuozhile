import { uiMaterial } from '@kit.ArkUI';
import { deviceInfo } from '@kit.BasicServicesKit';
import { normalizeImmersiveLevel } from './AppearanceOptions';

export function supportsImmersiveAppearance(): boolean {
  if (deviceInfo.apiAvailable('26.0.0')) {
    return uiMaterial.isImmersiveMaterialSupported();
  }
  return false;
}

function materialStyle(level: number): uiMaterial.ImmersiveStyle | undefined {
  if (deviceInfo.apiAvailable('26.0.0')) {
    switch (normalizeImmersiveLevel(level)) {
      case 1: return uiMaterial.ImmersiveStyle.ULTRA_THICK;
      case 2: return uiMaterial.ImmersiveStyle.THICK;
      case 4: return uiMaterial.ImmersiveStyle.THIN;
      case 5: return uiMaterial.ImmersiveStyle.ULTRA_THIN;
      default: return uiMaterial.ImmersiveStyle.REGULAR;
    }
  }
  return undefined;
}

export class ImmersiveSurface implements AttributeModifier<CommonAttribute> {
  private tint: ResourceColor;
  private level: number;
  private enabled: boolean;
  constructor(tint: ResourceColor = $r('app.color.material_tint'), level: number = 3, enabled: boolean = true) {
    this.tint = tint;
    this.level = normalizeImmersiveLevel(level);
    this.enabled = enabled;
  }
  applyNormalAttribute(instance: CommonAttribute): void {
    // Keep API 26 material creation and application out of the API 23 fallback path.
    if (deviceInfo.apiAvailable('26.0.0')) {
      if (!this.enabled) {
        instance.systemMaterial(uiMaterial.Material.empty);
        return;
      }
      instance.systemMaterial(new uiMaterial.ImmersiveMaterial({
        style: materialStyle(this.level),
        materialColor: this.tint,
        applyShadow: this.level >= 3,
        interactive: this.level >= 2,
        lightEffect: this.level >= 3 ? {} : null
      }));
    }
  }
}

// Content controls use a matching surface treatment independent of native bar materials.
export class ContentLightSurface implements AttributeModifier<CommonAttribute> {
  private level: number;
  private selected: boolean;
  constructor(level: number = 3, selected: boolean = true) {
    this.level = normalizeImmersiveLevel(level);
    this.selected = selected;
  }
  applyNormalAttribute(instance: CommonAttribute): void {
    const highlights: ResourceColor[] = [$r('app.color.control_highlight_1'),
      $r('app.color.control_highlight_2'), $r('app.color.control_highlight_3'),
      $r('app.color.control_highlight_4'), $r('app.color.control_highlight_5')];
    const highlight: ResourceColor = this.selected ? highlights[this.level - 1] : '#00000000';
    instance.linearGradient({ angle: 180, colors: [[highlight, 0], ['#00000000', 0.75]] })
      .border({ width: this.selected ? 0.5 + this.level * 0.1 : 0,
        color: $r('app.color.control_edge') })
      .shadow({ radius: this.selected ? this.level * 1.5 : 0, offsetY: this.selected ? 1 : 0,
        color: $r('app.color.shadow_card') });
  }
}

export class HarmonyTabBar implements AttributeModifier<TabsAttribute> {
  private level: number;
  constructor(level: number = 3) {
    this.level = normalizeImmersiveLevel(level);
  }
  applyNormalAttribute(instance: TabsAttribute): void {
    if (deviceInfo.apiAvailable('26.0.0')) {
      instance.barOverlap(true).barFloatingStyle({
        barSideMargin: 20, barBottomMargin: 8, maskHeight: 24, maskColor: $r('app.color.app_bg'),
        adaptToHandedness: false,
        systemMaterial: new uiMaterial.ImmersiveMaterial({
          style: materialStyle(this.level), materialColor: $r('app.color.material_tint'),
          applyShadow: this.level >= 3,
          interactive: this.level >= 2, lightEffect: this.level >= 3 ? {} : null
        })
      });
    } else {
      instance.barOverlap(false).barBackgroundColor($r('app.color.app_bg'));
    }
  }
}

export function navigationBottomInset(): number {
  return deviceInfo.apiAvailable('26.0.0') ? 96 : 24;
}

export function navigationTitleOptions(level: number = 3): NavigationTitleOptions {
  if (deviceInfo.apiAvailable('26.0.0')) {
    return {
      barStyle: BarStyle.STANDARD,
      systemMaterial: new uiMaterial.ImmersiveMaterial({
        style: materialStyle(level),
        materialColor: $r('app.color.material_tint'), applyShadow: false, interactive: false
      })
    };
  }
  return { backgroundColor: $r('app.color.app_bg'), barStyle: BarStyle.STANDARD };
}
