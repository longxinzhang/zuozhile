import { CalibrationProfile, PostureSample } from '../models/PostureTypes';

export enum PostureSourceKind {
  MOCK = 'mock',
  CORE_VISION = 'coreVision'
}

export interface PostureSourceStatus {
  kind: PostureSourceKind;
  label: string;
  detail: string;
  isLive: boolean;
}

export interface PostureSource {
  status(): PostureSourceStatus;
  sample(profile: CalibrationProfile): Promise<PostureSample>;
  dispose(): Promise<void>;
}
