import { CalibrationProfile, PostureSample } from '../models/PostureTypes';
import { createSimulatedSample } from './MockFrameSampler';
import { PostureSource, PostureSourceKind, PostureSourceStatus } from './PostureSource';

export class MockPostureSource implements PostureSource {
  private tick: number = 0;

  status(): PostureSourceStatus {
    return {
      kind: PostureSourceKind.MOCK,
      label: '模拟采样',
      detail: '用于验证 UI、评分和提醒流程',
      isLive: false
    };
  }

  async sample(profile: CalibrationProfile): Promise<PostureSample> {
    this.tick += 1;
    return createSimulatedSample(this.tick, profile);
  }

  async dispose(): Promise<void> {
    this.tick = 0;
  }
}
