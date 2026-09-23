import { abilityAccessCtrl, bundleManager, common } from '@kit.AbilityKit';
import { deviceInfo } from '@kit.BasicServicesKit';
import { display, floatView, window } from '@kit.ArkUI';

export class PostureFloatService {
  private static stage?: window.WindowStage;
  private static preview?: window.Window;
  private static controller?: floatView.FloatViewController;
  private static busy: boolean = false;
  private static nativeStarting: boolean = false;
  private static closing: boolean = false;
  private static closeRequested: boolean = false;
  private static deadline: number = -1;

  private static hasNativeDeclaration(): boolean {
    const bundle = bundleManager.getBundleInfoForSelfSync(
      bundleManager.BundleFlag.GET_BUNDLE_INFO_WITH_REQUESTED_PERMISSION);
    return bundle.reqPermissionDetails?.some((permission: bundleManager.ReqPermissionDetail) =>
      permission.name === 'ohos.permission.FLOAT_VIEW') ?? false;
  }

  private static nativeAvailable(): boolean {
    if (deviceInfo.apiAvailable('26.0.0')) {
      return floatView.isFloatViewEnabled();
    }
    return false;
  }

  static initialize(stage: window.WindowStage): void {
    PostureFloatService.stage = stage;
    AppStorage.setOrCreate('floatVisible', false);
    AppStorage.setOrCreate('floatNative', false);
    AppStorage.setOrCreate('floatBusy', false);
    AppStorage.setOrCreate('floatState', 'idle');
    AppStorage.setOrCreate('floatAvoidTop', 0);
    AppStorage.setOrCreate('floatAvoidBottom', 0);
    AppStorage.setOrCreate('floatMessage', '');
    let capability = '此系统仅支持应用内浮窗';
    try {
      if (PostureFloatService.nativeAvailable()) {
        capability = PostureFloatService.hasNativeDeclaration() ? '系统闪控窗可用' :
          '系统闪控窗待签名授权 · 当前为应用内浮窗';
      }
    } catch (_) {
      capability = '暂未确认系统闪控窗能力';
    }
    AppStorage.setOrCreate('floatCapability', capability);
  }

  private static updateBusy(): void {
    AppStorage.setOrCreate('floatBusy', PostureFloatService.busy || PostureFloatService.nativeStarting ||
      PostureFloatService.closing);
  }

  private static clearDeadline(): void {
    if (PostureFloatService.deadline >= 0) {
      clearTimeout(PostureFloatService.deadline);
      PostureFloatService.deadline = -1;
    }
  }

  private static cancelled(): boolean {
    return PostureFloatService.closeRequested || AppStorage.get<boolean>('appForeground') === false;
  }

  private static forgetController(controller: floatView.FloatViewController): void {
    if (PostureFloatService.controller !== controller) {
      return;
    }
    PostureFloatService.clearDeadline();
    try { controller.offStateChange(); } catch (_) {}
    try { controller.offRectChange(); } catch (_) {}
    PostureFloatService.controller = undefined;
    PostureFloatService.nativeStarting = false;
    PostureFloatService.closing = false;
    PostureFloatService.closeRequested = false;
    AppStorage.setOrCreate('floatVisible', false);
    PostureFloatService.updateBusy();
  }

  private static updateAvoidArea(controller: floatView.FloatViewController): void {
    try {
      const area = controller.getWindowProperties().avoidArea;
      AppStorage.setOrCreate('floatAvoidTop', area.topRect.height);
      AppStorage.setOrCreate('floatAvoidBottom', area.bottomRect.height);
    } catch (_) {}
  }

  static async open(context: common.UIAbilityContext): Promise<void> {
    if (PostureFloatService.busy || PostureFloatService.controller || PostureFloatService.preview) {
      return;
    }
    PostureFloatService.busy = true;
    PostureFloatService.closeRequested = false;
    AppStorage.setOrCreate('floatState', 'opening');
    AppStorage.setOrCreate('floatMessage', '正在准备浮窗');
    PostureFloatService.updateBusy();
    try {
      if (PostureFloatService.nativeAvailable() && PostureFloatService.hasNativeDeclaration()) {
        const permission = await abilityAccessCtrl.createAtManager().requestPermissionsFromUser(context,
          ['ohos.permission.FLOAT_VIEW']);
        if (permission.authResults[0] !== abilityAccessCtrl.GrantStatus.PERMISSION_GRANTED) {
          AppStorage.setOrCreate('floatState', 'idle');
          AppStorage.setOrCreate('floatMessage', '未获得闪控窗权限，可在系统设置中授权后重试');
          return;
        }
        if (PostureFloatService.cancelled()) {
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
          if (info.state === floatView.FloatViewState.STOPPED) {
            PostureFloatService.forgetController(controller);
            AppStorage.setOrCreate('floatState', 'idle');
            AppStorage.setOrCreate('floatMessage', '闪控窗已关闭');
          } else if (info.state === floatView.FloatViewState.ERROR) {
            PostureFloatService.forgetController(controller);
            AppStorage.setOrCreate('floatState', 'error');
            AppStorage.setOrCreate('floatMessage', '系统闪控窗异常，请重新开启');
          } else if (info.state === floatView.FloatViewState.STARTED) {
            if (PostureFloatService.closing) {
              return;
            }
            PostureFloatService.clearDeadline();
            PostureFloatService.nativeStarting = false;
            AppStorage.setOrCreate('floatVisible', true);
            AppStorage.setOrCreate('floatState', 'open');
            AppStorage.setOrCreate('floatMessage', '系统闪控窗已开启');
            PostureFloatService.updateAvoidArea(controller);
            PostureFloatService.updateBusy();
            if (PostureFloatService.closeRequested && !PostureFloatService.busy) {
              PostureFloatService.close();
            }
          } else if (!PostureFloatService.nativeStarting && !PostureFloatService.closing) {
            const inSidebar = info.state === floatView.FloatViewState.IN_SIDEBAR;
            AppStorage.setOrCreate('floatState', inSidebar ? 'sidebar' : 'hidden');
            AppStorage.setOrCreate('floatMessage', inSidebar ? '已收至系统侧边栏' : '系统闪控窗暂时隐藏');
          }
        });
        controller.onRectChange(() => { PostureFloatService.updateAvoidArea(controller); });
        await controller.setUIContext('pages/PostureFloat');
        const screen = display.getDefaultDisplaySync();
        const limits = floatView.getFloatViewLimits(floatView.FloatViewTemplateType.ROUNDED_RECTANGLE);
        await controller.setWindowSize({
          width: Math.round(Math.max(limits.minSize.width, Math.min(limits.maxSize.width, 260 * screen.densityPixels))),
          height: Math.round(Math.max(limits.minSize.height, Math.min(limits.maxSize.height, 210 * screen.densityPixels)))
        });
        if (PostureFloatService.cancelled()) {
          PostureFloatService.forgetController(controller);
          AppStorage.setOrCreate('floatState', 'idle');
          AppStorage.setOrCreate('floatMessage', '已取消开启浮窗');
          return;
        }
        PostureFloatService.nativeStarting = true;
        PostureFloatService.updateBusy();
        PostureFloatService.deadline = setTimeout(() => {
          if (PostureFloatService.controller === controller && PostureFloatService.nativeStarting) {
            PostureFloatService.nativeStarting = false;
            PostureFloatService.closeRequested = true;
            AppStorage.setOrCreate('floatMessage', '系统未确认开启，正在取消');
            PostureFloatService.close();
          }
        }, 10000);
        await controller.start();
      } else {
        if (!PostureFloatService.stage) {
          throw new Error('主窗口尚未就绪');
        }
        AppStorage.setOrCreate('floatNative', false);
        const preview = await PostureFloatService.stage.createSubWindow('posture_float_preview');
        PostureFloatService.preview = preview;
        const screen = display.getDefaultDisplaySync();
        const width = Math.min(Math.round(256 * screen.densityPixels), screen.width - 48);
        const height = Math.min(Math.round(214 * screen.densityPixels), screen.height - 96);
        await preview.resize(width, height);
        await preview.moveWindowTo(Math.max(24, screen.width - width - 24), Math.round(screen.height * 0.22));
        await preview.setUIContent('pages/PostureFloat');
        try { await preview.setWindowBackgroundColor('#00000000'); } catch (_) {}
        if (PostureFloatService.cancelled()) {
          return;
        }
        await preview.showWindow();
        AppStorage.setOrCreate('floatVisible', true);
        AppStorage.setOrCreate('floatState', 'open');
        AppStorage.setOrCreate('floatMessage', '应用内浮窗已开启；离开应用后关闭');
      }
    } catch (error) {
      AppStorage.setOrCreate('floatMessage', '浮窗未能开启：' + (error as Error).message);
      if (PostureFloatService.preview) {
        await PostureFloatService.preview.destroyWindow().catch(() => {});
        PostureFloatService.preview = undefined;
      }
      if (PostureFloatService.controller) {
        PostureFloatService.forgetController(PostureFloatService.controller);
      }
      AppStorage.setOrCreate('floatVisible', false);
      AppStorage.setOrCreate('floatState', 'error');
    } finally {
      PostureFloatService.busy = false;
      PostureFloatService.updateBusy();
      if (PostureFloatService.cancelled()) {
        await PostureFloatService.close();
      }
    }
  }

  static async close(): Promise<void> {
    if (PostureFloatService.busy || PostureFloatService.nativeStarting) {
      PostureFloatService.closeRequested = true;
      return;
    }
    if (PostureFloatService.closing) {
      return;
    }
    PostureFloatService.closing = true;
    AppStorage.setOrCreate('floatState', 'closing');
    PostureFloatService.updateBusy();
    try {
      if (PostureFloatService.preview) {
        await PostureFloatService.preview.destroyWindow();
        PostureFloatService.preview = undefined;
        AppStorage.setOrCreate('floatVisible', false);
      }
      const controller = PostureFloatService.controller;
      if (controller) {
        PostureFloatService.clearDeadline();
        PostureFloatService.deadline = setTimeout(() => {
          if (PostureFloatService.controller === controller) {
            PostureFloatService.closing = false;
            PostureFloatService.updateBusy();
            AppStorage.setOrCreate('floatMessage', '系统未确认关闭，请使用系统关闭按钮');
          }
        }, 10000);
        await controller.stop();
      } else {
        PostureFloatService.closing = false;
        PostureFloatService.closeRequested = false;
        AppStorage.setOrCreate('floatState', 'idle');
        AppStorage.setOrCreate('floatMessage', '浮窗已关闭');
      }
    } catch (_) {
      PostureFloatService.clearDeadline();
      PostureFloatService.closing = false;
      AppStorage.setOrCreate('floatState', 'error');
      AppStorage.setOrCreate('floatMessage', '关闭失败，请使用窗口关闭按钮');
    } finally {
      PostureFloatService.updateBusy();
    }
  }

  static async restore(context: common.UIAbilityContext): Promise<void> {
    try {
      if (deviceInfo.apiAvailable('26.0.0')) {
        if (PostureFloatService.controller) {
          await PostureFloatService.controller.restoreMainWindow();
          await PostureFloatService.close();
          return;
        }
      }
      await context.startAbility({ bundleName: 'com.longxin.zuozhile', abilityName: 'EntryAbility' });
      await PostureFloatService.close();
    } catch (error) {
      AppStorage.setOrCreate('floatMessage', '暂时无法返回，请从桌面打开坐直了');
      throw new Error((error as Error).message);
    }
  }

  static async background(): Promise<void> {
    if (PostureFloatService.busy || PostureFloatService.nativeStarting) {
      PostureFloatService.closeRequested = true;
    }
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
