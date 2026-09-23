export interface ARSample {
  rgba: ArrayBuffer;
  width: number;
  height: number;
  jawOpen: number;
  lipGapRatio: number;
  faceCount: number;
  timestampMs: number;
}

export const start: (context: Object) => void;
export const capture: () => Promise<ARSample>;
export const stop: () => void;
