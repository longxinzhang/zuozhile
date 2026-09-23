import { common } from '@kit.AbilityKit';
import { preferences } from '@kit.ArkData';
import { DEFAULT_IMMERSIVE_LEVEL, normalizeImmersiveLevel } from '../theme/AppearanceOptions';

const STORE_NAME = 'zuozhile_appearance';
const LEVEL_KEY = 'immersive_level';

export interface AppearanceLoadResult {
  level: number;
  isHealthy: boolean;
}

export class AppearanceStore {
  private static writeQueue: Promise<boolean> = Promise.resolve(true);

  static async load(context: common.UIAbilityContext): Promise<AppearanceLoadResult> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      const raw = await store.get(LEVEL_KEY, DEFAULT_IMMERSIVE_LEVEL);
      return { level: typeof raw === 'number' ? normalizeImmersiveLevel(raw) : DEFAULT_IMMERSIVE_LEVEL,
        isHealthy: true };
    } catch (error) {
      return { level: DEFAULT_IMMERSIVE_LEVEL, isHealthy: false };
    }
  }

  static save(context: common.UIAbilityContext, level: number): Promise<boolean> {
    // Serialize quick slider changes so an older write cannot win after a newer selection.
    AppearanceStore.writeQueue = AppearanceStore.writeQueue.then(() => AppearanceStore.write(context, level));
    return AppearanceStore.writeQueue;
  }

  private static async write(context: common.UIAbilityContext, level: number): Promise<boolean> {
    try {
      const store = await preferences.getPreferences(context, { name: STORE_NAME });
      await store.put(LEVEL_KEY, normalizeImmersiveLevel(level));
      await store.flush();
      return true;
    } catch (error) {
      return false;
    }
  }
}
