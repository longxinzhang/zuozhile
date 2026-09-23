export const DEFAULT_IMMERSIVE_LEVEL: number = 3;

export function normalizeImmersiveLevel(value: number): number {
  if (!Number.isFinite(value)) {
    return DEFAULT_IMMERSIVE_LEVEL;
  }
  return Math.max(1, Math.min(5, Math.round(value)));
}
