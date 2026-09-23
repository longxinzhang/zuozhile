import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PostureFloatService } from '../services/PostureFloatService';
import { GuardWindowService } from '../services/GuardWindowService';
import { supportsFaceTracking } from '../services/ARFaceCapability';
import { AppearanceStore } from '../services/AppearanceStore';

const DOMAIN = 0x0000;
const TAG = 'Zuozhile';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('appForeground', true);
    AppStorage.setOrCreate('immersiveLevel', 3);
    AppStorage.setOrCreate('appearanceReady', false);
    AppStorage.setOrCreate('appearanceError', '');
    AppearanceStore.load(this.context).then(result => {
      AppStorage.setOrCreate('immersiveLevel', result.level);
      AppStorage.setOrCreate('appearanceError', result.isHealthy ? '' : '外观设置读取失败，已使用默认值');
      AppStorage.setOrCreate('appearanceReady', true);
    });
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Failed to set color mode: %{public}s', JSON.stringify(error));
    }
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
    hilog.info(DOMAIN, TAG, 'Face tracking supported: %{public}s', supportsFaceTracking().toString());
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    PostureFloatService.initialize(windowStage);
    try {
      const mainWindow = windowStage.getMainWindowSync();
      this.mainWindow = mainWindow;
      GuardWindowService.setMainWindow(mainWindow);
      this.updateSystemBars(this.context.config.colorMode);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Main window appearance unavailable');
    }
    windowStage.loadContent('pages/Index', (err) => {
      if (err.code) {
        hilog.error(DOMAIN, TAG, 'Failed to load content: %{public}s', JSON.stringify(err));
        return;
      }
      hilog.info(DOMAIN, TAG, 'Loaded main page');
    });
  }

  onWindowStageDestroy(): void {
    this.mainWindow = undefined;
    PostureFloatService.close();
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    this.updateSystemBars(this.context.config.colorMode);
    AppStorage.setOrCreate('appForeground', true);
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate('appForeground', false);
    PostureFloatService.background();
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.updateSystemBars(newConfig.colorMode);
  }

  private updateSystemBars(mode?: ConfigurationConstant.ColorMode): void {
    const dark = (mode ?? this.context.config.colorMode) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    // System bar APIs take resolved strings, not ArkUI color resources.
    const background = dark ? '#111315' : '#F4F5F7';
    const foreground = dark ? '#F0F2F4' : '#1D2329';
    this.mainWindow?.setWindowSystemBarProperties({
      statusBarColor: background, navigationBarColor: background,
      statusBarContentColor: foreground, navigationBarContentColor: foreground
    }).catch(() => { hilog.warn(DOMAIN, TAG, 'System bar appearance update failed'); });
  }
}
