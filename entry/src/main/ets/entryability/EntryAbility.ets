import { AbilityConstant, Configuration, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PostureFloatService } from '../services/PostureFloatService';
import { GuardWindowService } from '../services/GuardWindowService';
import { supportsFaceTracking } from '../services/ARFaceCapability';
import { AppearanceStore } from '../services/AppearanceStore';
import { WearableReminderService } from '../services/WearableReminderService';

const DOMAIN = 0x0000;
const TAG = 'Zuozhile';

export default class EntryAbility extends UIAbility {
  private mainWindow?: window.Window;
  private windowSizeListener: (size: window.Size) => void = (size: window.Size): void => {
    this.publishScreenSize(size.width, size.height);
    this.publishTopAvoidInset();
  };
  private avoidAreaListener: (options: window.AvoidAreaOptions) => void =
    (options: window.AvoidAreaOptions): void => {
      if (options.type === window.AvoidAreaType.TYPE_SYSTEM || options.type === window.AvoidAreaType.TYPE_CUTOUT) {
        this.publishTopAvoidInset();
      }
    };

  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('appForeground', true);
    AppStorage.setOrCreate('mainWindowTopInsetPx', 0);
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
    WearableReminderService.destroy();
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    PostureFloatService.initialize(windowStage);
    try {
      const mainWindow = windowStage.getMainWindowSync();
      this.mainWindow = mainWindow;
      mainWindow.setWindowLayoutFullScreen(true).then((): void => {
        if (this.mainWindow !== mainWindow) {
          return;
        }
        const rect = mainWindow.getWindowProperties().windowRect;
        this.publishScreenSize(rect.width, rect.height);
        this.publishTopAvoidInset();
      }).catch((): void => { hilog.warn(DOMAIN, TAG, 'Full-screen glow layout unavailable'); });
      mainWindow.on('windowSizeChange', this.windowSizeListener);
      mainWindow.on('avoidAreaChange', this.avoidAreaListener);
      this.publishTopAvoidInset();
      const rect = mainWindow.getWindowProperties().windowRect;
      this.publishScreenSize(rect.width, rect.height);
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
      this.publishTopAvoidInset();
      hilog.info(DOMAIN, TAG, 'Loaded main page');
    });
  }

  onWindowStageDestroy(): void {
    WearableReminderService.controller.suspend();
    try {
      this.mainWindow?.off('windowSizeChange', this.windowSizeListener);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Window size listener cleanup failed');
    }
    try {
      this.mainWindow?.off('avoidAreaChange', this.avoidAreaListener);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Window avoid-area listener cleanup failed');
    }
    this.mainWindow = undefined;
    AppStorage.setOrCreate('mainWindowTopInsetPx', 0);
    PostureFloatService.close();
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    this.updateSystemBars(this.context.config.colorMode);
    this.publishTopAvoidInset();
    AppStorage.setOrCreate('appForeground', true);
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    WearableReminderService.controller.suspend();
    AppStorage.setOrCreate('appForeground', false);
    PostureFloatService.background();
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }

  onConfigurationUpdate(newConfig: Configuration): void {
    this.updateSystemBars(newConfig.colorMode);
  }

  private updateSystemBars(mode?: ConfigurationConstant.ColorMode): void {
    const dark = (mode ?? this.context.config.colorMode) === ConfigurationConstant.ColorMode.COLOR_MODE_DARK;
    AppStorage.setOrCreate('appColorMode', dark ? 0 : 1);
    // System bar APIs take resolved strings, not ArkUI color resources.
    const foreground = dark ? '#F0F2F4' : '#1D2329';
    this.mainWindow?.setWindowSystemBarProperties({
      statusBarColor: '#00000000', navigationBarColor: '#00000000',
      statusBarContentColor: foreground, navigationBarContentColor: foreground
    }).catch(() => { hilog.warn(DOMAIN, TAG, 'System bar appearance update failed'); });
  }
  private publishScreenSize(width: number, height: number): void {
    AppStorage.setOrCreate('glowWindowWidthPx', width);
    AppStorage.setOrCreate('glowWindowHeightPx', height);
  }

  private publishTopAvoidInset(): void {
    const mainWindow = this.mainWindow;
    if (mainWindow === undefined) {
      return;
    }
    try {
      const systemTop = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_SYSTEM).topRect;
      const cutoutTop = mainWindow.getWindowAvoidArea(window.AvoidAreaType.TYPE_CUTOUT).topRect;
      const systemBottom = systemTop.height > 0 ? systemTop.top + systemTop.height : 0;
      const cutoutBottom = cutoutTop.height > 0 ? cutoutTop.top + cutoutTop.height : 0;
      AppStorage.setOrCreate('mainWindowTopInsetPx', Math.max(0, systemBottom, cutoutBottom));
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Window top avoid area unavailable');
    }
  }
}
