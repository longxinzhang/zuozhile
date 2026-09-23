import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display, floatView, window } from '@kit.ArkUI';

export class PostureFloatService {
  private static stage?: window.WindowStage;
  private static preview?: window.Window;
  private static controller?: floatView.FloatViewController;
  private static busy: boolean = false;
  private static nativeStarting: boolean = false;
  private static closeRequested: boolean = false;

  private static hasNativeDeclaration(): boolean {
    const bundle = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION);
    return bundle.reqPermissionDetails?.some((permission: bundleManager.ReqPermissionDetail) =>
      permission.name === 'ohos.permission.FLOAT_VIEW') ?? false;
  }

  static initialize(stage: window.WindowStage): void {
    PostureFloatService.stage = stage;
    AppStorage.setOrCreate('floatVisible', false);
    AppStorage.setOrCreate('floatNative', false);
    AppStorage.setOrCreate('floatMessage', '');
  }

  static async open(context: common.UIAbilityContext): Promise<void> {
    if (PostureFloatService.busy || PostureFloatService.nativeStarting || AppStorage.get<boolean>('floatVisible')) {
      return;
    }
    PostureFloatService.busy = true;
    try {
      if (deviceInfo.apiAvailable('26.0.0') && PostureFloatService.hasNativeDeclaration() && floatView.isFloatViewEnabled()) {
        const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,
          ['ohos.permission.FLOAT_VIEW']);
        if (permission.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          AppStorage.setOrCreate('floatMessage', '未获得闪控窗权限，可在系统设置中授权后重试');
          return;
        }
        AppStorage.setOrCreate('floatNative', true);
        const controller = await floatView.create({ context,
          templateType: floatView.FloatViewTemplateType.ROUNDED_RECTANGLE });
        PostureFloatService.controller = controller;
        controller.onStateChange((info: floatView.FloatViewStateChangeInfo) => {
          if (PostureFloatService.controller !== controller) {
            return;
          }
          const started = info.state === floatView.FloatViewState.STARTED;
          if (started || info.state === floatView.FloatViewState.STOPPED) {
            PostureFloatService.nativeStarting = false;
            AppStorage.setOrCreate('floatVisible', started);
            AppStorage.setOrCreate('floatMessage', started ? '系统闪控窗已开启' : '闪控窗已关闭');
          }
          if (started && PostureFloatService.closeRequested) {
            PostureFloatService.closeRequested = false;
            PostureFloatService.close();
          }
          if (info.state === floatView.FloatViewState.STOPPED) {
            PostureFloatService.controller = undefined;
            controller.offStateChange();
          }
        });
        await controller.setUIContext('pages/PostureFloat');
        PostureFloatService.nativeStarting = true;
        AppStorage.setOrCreate('floatMessage', '正在开启系统闪控窗');
        await controller.start();
      } else {
        // Older systems get a real child-window preview, never a claimed cross-app float view.
        if (!PostureFloatService.stage) {
          throw new Error('主窗口尚未就绪');
        }
        AppStorage.setOrCreate('floatNative', false);
        const preview = await PostureFloatService.stage.createSubWindow('posture_float_preview');
        PostureFloatService.preview = preview;
        const screen = display.getDefaultDisplaySync();
        const width = Math.min(Math.round(280 * screen.densityPixels), screen.width - 48);
        const height = Math.round(210 * screen.densityPixels);
        await preview.resize(width, height);
        await preview.moveWindowTo(Math.max(24, screen.width - width - 24), Math.round(screen.height * 0.25));
        await preview.setUIContent('pages/PostureFloat');
        // Some phones do not allow changing a child-window background.
        try {
          await preview.setWindowBackgroundColor('#00000000');
        } catch (error) {
        }
        await preview.showWindow();
        AppStorage.setOrCreate('floatVisible', true);
        AppStorage.setOrCreate('floatMessage', '应用内浮窗预览；跨应用闪控窗待系统与权限适配');
      }
    } catch (error) {
      AppStorage.setOrCreate('floatMessage', '浮窗未能开启：' + (error as Error).message);
      if (PostureFloatService.preview) {
        await PostureFloatService.preview.destroyWindow().catch(() => {});
        PostureFloatService.preview = undefined;
      }
      try {
        PostureFloatService.controller?.offStateChange();
      } catch (ignored) {
      }
      PostureFloatService.controller = undefined;
      PostureFloatService.nativeStarting = false;
      PostureFloatService.closeRequested = false;
      AppStorage.setOrCreate('floatVisible', false);
    } finally {
      PostureFloatService.busy = false;
    }
  }

  static async close(): Promise<void> {
    if (PostureFloatService.nativeStarting) {
      PostureFloatService.closeRequested = true;
      return;
    }
    try {
      if (PostureFloatService.preview) {
        await PostureFloatService.preview.destroyWindow();
        PostureFloatService.preview = undefined;
        AppStorage.setOrCreate('floatVisible', false);
      }
      if (PostureFloatService.controller && AppStorage.get<boolean>('floatVisible')) {
        await PostureFloatService.controller.stop();
      }
    } catch (error) {
      AppStorage.setOrCreate('floatMessage', '关闭失败，请使用窗口关闭按钮');
    }
  }

  static async background(): Promise<void> {
    if (PostureFloatService.preview) {
      await PostureFloatService.close();
    }
  }

  static move(): void {
    PostureFloatService.preview?.startMoving().catch(() => {
      AppStorage.setOrCreate('floatMessage', '此设备不支持拖动预览窗口');
    });
  }
}
