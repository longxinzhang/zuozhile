import { inspectCalibrationSamples } from './PostureCalibration';
import { PostureSample } from './PostureTypes';

export interface CalibrationCaptureResult {
  samples: PostureSample[];
  isUsable: boolean;
  cancelled: boolean;
  detail: string;
}

export async function captureCalibration(
  sample: () => Promise<PostureSample>,
  cancelled: () => boolean,
  progress: (completed: number, total: number) => void,
  count: number
): Promise<CalibrationCaptureResult> {
  const samples: PostureSample[] = [];
  const startedAt = Date.now();
  for (let index = 0; index < count; index += 1) {
    if (cancelled()) {
      return { samples: [], isUsable: false, cancelled: true, detail: '已取消校准' };
    }
    const frame = await sample();
    if (cancelled()) {
      return { samples: [], isUsable: false, cancelled: true, detail: '已取消校准' };
    }
    samples.push(frame);
    progress(samples.length, count);
    if (Date.now() - startedAt > 15000 && samples.length < count) {
      return { samples, isUsable: false, cancelled: false, detail: '校准采样超时，请重试' };
    }
  }
  const quality = inspectCalibrationSamples(samples);
  return { samples, isUsable: quality.isUsable, cancelled: false, detail: quality.detail };
}
