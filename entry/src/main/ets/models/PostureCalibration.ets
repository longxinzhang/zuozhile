import {
  CalibrationProfile,
  Point2D,
  PostureSample,
  createDefaultCalibration
} from './PostureTypes';

const MIN_POINT_SCORE = 0.35;
const MIN_VALID_FACE_FRAMES = 5;
const MIN_VALID_SHOULDER_FRAMES = 5;
const MIN_VALID_NOSE_SHOULDER_FRAMES = 3;

export interface CalibrationSampleQuality {
  totalCount: number;
  faceCount: number;
  shoulderCount: number;
  noseShoulderCount: number;
  isUsable: boolean;
  detail: string;
}

function reliable(point?: Point2D): boolean {
  return point !== undefined && point.score >= MIN_POINT_SCORE;
}

function median(values: number[], fallback: number): number {
  const scoped = values.filter((value: number) => Number.isFinite(value));
  if (scoped.length === 0) {
    return fallback;
  }
  const sorted = scoped.sort((left: number, right: number) => left - right);
  const mid = Math.floor(sorted.length / 2);
  if (sorted.length % 2 === 1) {
    return sorted[mid];
  }
  return (sorted[mid - 1] + sorted[mid]) / 2;
}

function shoulderWidth(left: Point2D, right: Point2D): number {
  return Math.max(Math.abs(left.x - right.x), 1);
}

function shoulderMidY(left: Point2D, right: Point2D): number {
  return (left.y + right.y) / 2;
}

function neckAngle(nose: Point2D, left: Point2D, right: Point2D): number {
  const shoulderMidX = (left.x + right.x) / 2;
  const shoulderMid = shoulderMidY(left, right);
  const dx = nose.x - shoulderMidX;
  const dy = shoulderMid - nose.y;
  if (dy <= 0) {
    return 90;
  }
  return Math.atan2(Math.abs(dx), Math.abs(dy)) * 180 / Math.PI;
}

export function inspectCalibrationSamples(samples: PostureSample[]): CalibrationSampleQuality {
  let faceCount = 0;
  let shoulderCount = 0;
  let noseShoulderCount = 0;
  samples.forEach((sample: PostureSample) => {
    if (sample.face.confidence >= 0.25) {
      faceCount += 1;
    }
    const nose = sample.skeleton.nose;
    const left = sample.skeleton.leftShoulder;
    const right = sample.skeleton.rightShoulder;
    if (reliable(left) && reliable(right)) {
      shoulderCount += 1;
      if (reliable(nose)) {
        noseShoulderCount += 1;
      }
    }
  });

  if (faceCount < MIN_VALID_FACE_FRAMES) {
    return {
      totalCount: samples.length,
      faceCount,
      shoulderCount,
      noseShoulderCount,
      isUsable: false,
      detail: '人脸识别不足，请正对屏幕并保持脸在画面内'
    };
  }
  if (shoulderCount < MIN_VALID_SHOULDER_FRAMES) {
    return {
      totalCount: samples.length,
      faceCount,
      shoulderCount,
      noseShoulderCount,
      isUsable: false,
      detail: '肩膀识别不足，请让头肩和上半身进入画面'
    };
  }
  if (noseShoulderCount < MIN_VALID_NOSE_SHOULDER_FRAMES) {
    return {
      totalCount: samples.length,
      faceCount,
      shoulderCount,
      noseShoulderCount,
      isUsable: false,
      detail: '头肩关键点不足，请摆好健康姿势后重试'
    };
  }
  return {
    totalCount: samples.length,
    faceCount,
    shoulderCount,
    noseShoulderCount,
    isUsable: true,
    detail: '校准样本有效'
  };
}

export function buildCalibrationProfile(samples: PostureSample[], previous?: CalibrationProfile): CalibrationProfile {
  const fallback = previous ? previous : createDefaultCalibration();
  const pitchValues: number[] = [];
  const rollValues: number[] = [];
  const yawValues: number[] = [];
  const mouthValues: number[] = [];
  const faceCenterYValues: number[] = [];
  const faceHeightValues: number[] = [];
  const faceAreaValues: number[] = [];
  const neckAngleValues: number[] = [];
  const shoulderTiltValues: number[] = [];
  const shoulderMidYValues: number[] = [];
  const shoulderWidthValues: number[] = [];
  const noseRatioValues: number[] = [];

  samples.forEach((sample: PostureSample) => {
    if (sample.face.confidence >= 0.25) {
      pitchValues.push(sample.face.pitch);
      rollValues.push(sample.face.roll);
      yawValues.push(sample.face.yaw);
      mouthValues.push(sample.face.mouthOpenRatio);
      if (sample.face.rect) {
        faceCenterYValues.push(sample.face.rect.top + sample.face.rect.height / 2);
        faceHeightValues.push(sample.face.rect.height);
        faceAreaValues.push(sample.face.rect.width * sample.face.rect.height);
      }
    }

    const nose = sample.skeleton.nose;
    const left = sample.skeleton.leftShoulder;
    const right = sample.skeleton.rightShoulder;
    if (reliable(left) && reliable(right)) {
      const width = shoulderWidth(left as Point2D, right as Point2D);
      shoulderWidthValues.push(width);
      shoulderMidYValues.push(shoulderMidY(left as Point2D, right as Point2D));
      shoulderTiltValues.push(((left as Point2D).y - (right as Point2D).y) / width);
      if (reliable(nose)) {
        neckAngleValues.push(neckAngle(nose as Point2D, left as Point2D, right as Point2D));
        noseRatioValues.push(((nose as Point2D).y - shoulderMidY(left as Point2D, right as Point2D)) / width);
      }
    }
  });

  return {
    neutralNeckAngle: median(neckAngleValues, fallback.neutralNeckAngle),
    neutralShoulderTilt: median(shoulderTiltValues, fallback.neutralShoulderTilt),
    neutralPitch: median(pitchValues, fallback.neutralPitch),
    neutralRoll: median(rollValues, fallback.neutralRoll),
    neutralYaw: median(yawValues, fallback.neutralYaw),
    neutralMouthRatio: median(mouthValues, fallback.neutralMouthRatio),
    neutralFaceCenterY: median(faceCenterYValues, fallback.neutralFaceCenterY),
    neutralFaceHeight: Math.max(1, median(faceHeightValues, fallback.neutralFaceHeight)),
    neutralFaceArea: Math.max(1, median(faceAreaValues, fallback.neutralFaceArea)),
    neutralShoulderMidY: median(shoulderMidYValues, fallback.neutralShoulderMidY),
    neutralShoulderWidth: Math.max(1, median(shoulderWidthValues, fallback.neutralShoulderWidth)),
    neutralNoseToShoulderRatio: median(noseRatioValues, fallback.neutralNoseToShoulderRatio),
    calibratedAt: Date.now(),
    sensitivity: fallback.sensitivity,
    sampleIntervalMs: fallback.sampleIntervalMs
  };
}
