import { AbilityConstant, ConfigurationConstant, UIAbility, Want } from '@kit.AbilityKit';
import { hilog } from '@kit.PerformanceAnalysisKit';
import { window } from '@kit.ArkUI';
import { PostureFloatService } from '../services/PostureFloatService';
import { GuardWindowService } from '../services/GuardWindowService';

const DOMAIN = 0x0000;
const TAG = 'Zuozhile';

export default class EntryAbility extends UIAbility {
  onCreate(want: Want, launchParam: AbilityConstant.LaunchParam): void {
    AppStorage.setOrCreate('appForeground', true);
    try {
      this.context.getApplicationContext().setColorMode(ConfigurationConstant.ColorMode.COLOR_MODE_NOT_SET);
    } catch (error) {
      hilog.warn(DOMAIN, TAG, 'Failed to set color mode: %{public}s', JSON.stringify(error));
    }
    hilog.info(DOMAIN, TAG, 'Ability onCreate');
  }

  onDestroy(): void {
    hilog.info(DOMAIN, TAG, 'Ability onDestroy');
  }

  onWindowStageCreate(windowStage: window.WindowStage): void {
    PostureFloatService.initialize(windowStage);
    try {
      const mainWindow = windowStage.getMainWindowSync();
      GuardWindowService.setMainWindow(mainWindow);
      mainWindow.setWindowSystemBarProperties({
        statusBarColor: '#F2F3F5', navigationBarColor: '#F2F3F5',
        statusBarContentColor: '#20252D', navigationBarContentColor: '#20252D'
      }).catch(() => {});
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
    PostureFloatService.close();
    hilog.info(DOMAIN, TAG, 'Ability onWindowStageDestroy');
  }

  onForeground(): void {
    AppStorage.setOrCreate('appForeground', true);
    hilog.info(DOMAIN, TAG, 'Ability onForeground');
  }

  onBackground(): void {
    AppStorage.setOrCreate('appForeground', false);
    PostureFloatService.background();
    hilog.info(DOMAIN, TAG, 'Ability onBackground');
  }
}
