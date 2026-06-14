import {
  CalibrationProfile,
  FaceFrame,
  MetricResult,
  Point2D,
  PostureAlertType,
  PostureLevel,
  PostureResult,
  PostureSample,
  ReminderAction,
  SkeletonFrame
} from './PostureTypes';

const MIN_POINT_SCORE = 0.35;
const SENSITIVE_MODE_THRESHOLD = 1.05;
const POSTURE_ALERT_PRIORITY: PostureAlertType[] = [
  PostureAlertType.ITEM_02,
  PostureAlertType.ITEM_01,
  PostureAlertType.ITEM_07,
  PostureAlertType.ITEM_03,
  PostureAlertType.ITEM_05,
  PostureAlertType.ITEM_10,
  PostureAlertType.ITEM_06,
  PostureAlertType.ITEM_11,
  PostureAlertType.ITEM_12
];

function finiteOr(value: number, fallback: number): number {
  return Number.isFinite(value) ? value : fallback;
}

function clamp(value: number, min: number, max: number): number {
  const safeValue = finiteOr(value, min);
  if (safeValue < min) {
    return min;
  }
  if (safeValue > max) {
    return max;
  }
  return safeValue;
}

function reliable(point?: Point2D): boolean {
  if (!point) {
    return false;
  }
  return point.score >= MIN_POINT_SCORE;
}

function distance(a: Point2D, b: Point2D): number {
  const dx = a.x - b.x;
  const dy = a.y - b.y;
  return Math.sqrt(dx * dx + dy * dy);
}

function midpoint(a: Point2D, b: Point2D): Point2D {
  return {
    x: (a.x + b.x) / 2,
    y: (a.y + b.y) / 2,
    score: Math.min(a.score, b.score)
  };
}

function angleFromVertical(head: Point2D, anchor: Point2D): number {
  const dx = head.x - anchor.x;
  const dy = anchor.y - head.y;
  if (dy <= 0) {
    return 90;
  }
  return Math.atan2(Math.abs(dx), Math.abs(dy)) * 180 / Math.PI;
}

function levelFromDelta(delta: number, warn: number, bad: number): PostureLevel {
  if (delta >= bad) {
    return PostureLevel.BAD;
  }
  if (delta >= warn) {
    return PostureLevel.WARN;
  }
  return PostureLevel.GOOD;
}

function levelFromAlert(warn: boolean, bad: boolean): PostureLevel {
  if (bad) {
    return PostureLevel.BAD;
  }
  if (warn) {
    return PostureLevel.WARN;
  }
  return PostureLevel.GOOD;
}

function scoreFromLevel(level: PostureLevel, delta: number, bad: number): number {
  if (level === PostureLevel.UNKNOWN) {
    return 68;
  }
  if (level === PostureLevel.GOOD) {
    return clamp(96 - delta * 1.4, 82, 100);
  }
  if (level === PostureLevel.WARN) {
    return clamp(82 - delta * 1.7, 58, 82);
  }
  return clamp(58 - (delta - bad) * 2.1, 20, 58);
}

function makeMetric(
  level: PostureLevel,
  value: number,
  baseline: number,
  score: number,
  label: string,
  alertType: PostureAlertType = PostureAlertType.NONE
): MetricResult {
  const safeBaseline = finiteOr(baseline, 0);
  return {
    level,
    value: finiteOr(value, safeBaseline),
    baseline: safeBaseline,
    score: Math.round(clamp(score, 0, 100)),
    label,
    alertType
  };
}

function faceCenterY(face: FaceFrame): number {
  if (!face.rect) {
    return 0;
  }
  return face.rect.top + face.rect.height / 2;
}

function faceArea(face: FaceFrame): number {
  if (!face.rect) {
    return 1;
  }
  return Math.max(face.rect.width * face.rect.height, 1);
}

function shoulderWidthHorizontal(left: Point2D, right: Point2D): number {
  return Math.max(Math.abs(left.x - right.x), 1);
}

function shoulderMidY(left: Point2D, right: Point2D): number {
  return (left.y + right.y) / 2;
}

function noseToShoulderRatio(nose: Point2D, left: Point2D, right: Point2D): number {
  return (nose.y - shoulderMidY(left, right)) / shoulderWidthHorizontal(left, right);
}

function scaled(base: number, sensitivity: number): number {
  return base / sensitivity;
}

function compressionThreshold(loss: number, sensitivity: number): number {
  return 1 - loss / sensitivity;
}

function expansionThreshold(gain: number, sensitivity: number): number {
  return 1 + gain / sensitivity;
}

function orderedActiveAlerts(candidates: PostureAlertType[]): PostureAlertType[] {
  const active: PostureAlertType[] = [];
  POSTURE_ALERT_PRIORITY.forEach((type: PostureAlertType) => {
    if (candidates.includes(type)) {
      active.push(type);
    }
  });
  return active;
}

function evaluateSit(skeleton: SkeletonFrame, face: FaceFrame, profile: CalibrationProfile): MetricResult {
  const sensitivity = Math.max(profile.sensitivity, 0.6);
  const ls = skeleton.leftShoulder;
  const rs = skeleton.rightShoulder;
  if (!reliable(ls) || !reliable(rs)) {
    if (face.confidence >= 0.25) {
      const deltaRoll = Math.abs(face.roll - profile.neutralRoll);
      const warnRoll = 10 / sensitivity;
      const badRoll = 18 / sensitivity;
      const level = levelFromDelta(deltaRoll, warnRoll, badRoll);
      let label = '肩颈稳定';
      if (level === PostureLevel.WARN) {
        label = '头有点歪';
      } else if (level === PostureLevel.BAD) {
        label = '头歪明显';
      }
      return makeMetric(level, deltaRoll, profile.neutralRoll, scoreFromLevel(level, deltaRoll, badRoll), label,
        level === PostureLevel.GOOD ? PostureAlertType.NONE : PostureAlertType.ITEM_06);
    }
    return makeMetric(PostureLevel.UNKNOWN, 0, profile.neutralShoulderTilt, 68, '未识别上半身');
  }

  const left = ls as Point2D;
  const right = rs as Point2D;
  const shoulderWidth = shoulderWidthHorizontal(left, right);
  const tiltRatio = (left.y - right.y) / shoulderWidth;
  const deltaTilt = Math.abs(tiltRatio - profile.neutralShoulderTilt);
  const deltaRoll = face.confidence >= 0.25 ? Math.abs(face.roll - profile.neutralRoll) : 0;
  const warnTilt = scaled(0.06, sensitivity);
  const badTilt = scaled(0.10, sensitivity);
  const warnRoll = scaled(10, sensitivity);
  const badRoll = scaled(18, sensitivity);

  const currentFaceCenterY = faceCenterY(face);
  const currentShoulderMidY = shoulderMidY(left, right);
  const deltaFaceY = profile.neutralFaceCenterY > 0 ?
    (currentFaceCenterY - profile.neutralFaceCenterY) / Math.max(profile.neutralFaceHeight, 1) : 0;
  const deltaShoulderY = profile.neutralShoulderMidY > 0 ?
    (currentShoulderMidY - profile.neutralShoulderMidY) / Math.max(profile.neutralShoulderWidth, 1) : 0;
  const slideWarn = deltaFaceY > scaled(0.28, sensitivity) && deltaShoulderY > scaled(0.08, sensitivity);
  const slideBad = deltaFaceY > scaled(0.45, sensitivity) && deltaShoulderY > scaled(0.14, sensitivity);

  const compression = shoulderWidth / Math.max(profile.neutralShoulderWidth, 1);
  const expansion = faceArea(face) / Math.max(profile.neutralFaceArea, 1);
  const sensitiveMode = sensitivity > SENSITIVE_MODE_THRESHOLD;
  const compressionLoss = Math.max(0, 1 - compression);
  const faceExpansionDelta = Math.max(0, expansion - 1);
  const hasShoulderBaseline = profile.neutralShoulderWidth > 1;
  const shouldersRounded = hasShoulderBaseline && compression < compressionThreshold(0.12, sensitivity);
  const shouldersRoundedBad = hasShoulderBaseline && compression < compressionThreshold(sensitiveMode ? 0.18 : 0.24, sensitivity);
  const notLeaningForward = expansion < expansionThreshold(0.15, sensitivity);
  const leaningForward = face.confidence >= 0.25 && expansion > expansionThreshold(0.18, sensitivity);
  const leaningForwardBad = face.confidence >= 0.25 && expansion > expansionThreshold(0.28, sensitivity);
  const faceNotDropped = deltaFaceY < scaled(0.25, sensitivity);
  const bodyTiltWarn = deltaTilt > scaled(0.06, sensitivity) && deltaRoll > scaled(8, sensitivity);
  const bodyTiltBad = deltaTilt > badTilt && deltaRoll > badRoll;
  const kyphosisWarn = shouldersRounded && notLeaningForward;
  const kyphosisBad = shouldersRoundedBad && notLeaningForward;
  const chairSupportWarn = (leaningForward && faceNotDropped) || slideWarn;
  const chairSupportBad = (leaningForwardBad && faceNotDropped) || slideBad;
  const headOnlyTiltWarn = deltaRoll > scaled(10, sensitivity) && deltaTilt < scaled(0.04, sensitivity);
  const headOnlyTiltBad = deltaRoll > badRoll && deltaTilt < scaled(0.05, sensitivity);
  const tiltWarn = bodyTiltWarn || headOnlyTiltWarn;
  const tiltBad = bodyTiltBad || headOnlyTiltBad;
  const level = levelFromAlert(chairSupportWarn || kyphosisWarn || tiltWarn,
    chairSupportBad || kyphosisBad || tiltBad);

  let label = '肩颈稳定';
  let alertType = PostureAlertType.NONE;
  if (bodyTiltBad || bodyTiltWarn) {
    label = bodyTiltBad ? '身体歪斜' : '左右不平';
    alertType = PostureAlertType.ITEM_02;
  } else if (kyphosisBad || kyphosisWarn) {
    if (kyphosisBad) {
      label = '肩膀前扣';
    } else {
      label = '含胸趋势';
    }
    alertType = PostureAlertType.ITEM_01;
  } else if (chairSupportBad || chairSupportWarn) {
    label = chairSupportBad ? '靠回椅背' : '身体靠前';
    alertType = PostureAlertType.ITEM_07;
  } else if (headOnlyTiltBad || headOnlyTiltWarn) {
    label = headOnlyTiltBad ? '头歪明显' : '头有点歪';
    alertType = PostureAlertType.ITEM_06;
  }

  const tiltPressure = deltaTilt / Math.max(warnTilt, 0.01);
  const rollPressure = deltaRoll / Math.max(warnRoll, 1);
  const slidePressure = Math.max(deltaFaceY / 0.35, deltaShoulderY / 0.10);
  let kyphosisPressure = 0;
  if (hasShoulderBaseline) {
    kyphosisPressure = Math.max(
      compressionLoss / Math.max(scaled(0.12, sensitivity), 0.01),
      faceExpansionDelta / Math.max(scaled(0.18, sensitivity), 0.01)
    );
  }
  const pressure = Math.max(tiltPressure, rollPressure, slidePressure, kyphosisPressure);
  return makeMetric(level, pressure * 100, 100, scoreFromLevel(level, pressure * 10, 18), label, alertType);
}

function evaluateChin(face: FaceFrame, skeleton: SkeletonFrame, profile: CalibrationProfile): MetricResult {
  const sensitivity = Math.max(profile.sensitivity, 0.6);
  if (face.confidence < 0.25) {
    return makeMetric(PostureLevel.UNKNOWN, face.pitch, profile.neutralPitch, 68, '未识别人脸');
  }
  const pitchDelta = Math.abs(face.pitch - profile.neutralPitch);
  let noseDrop = 0;
  if (reliable(skeleton.nose) && reliable(skeleton.leftShoulder) && reliable(skeleton.rightShoulder)) {
    noseDrop = Math.max(0, noseToShoulderRatio(
      skeleton.nose as Point2D,
      skeleton.leftShoulder as Point2D,
      skeleton.rightShoulder as Point2D
    ) - profile.neutralNoseToShoulderRatio);
  }
  const warnPitch = scaled(13, sensitivity);
  const badPitch = scaled(25, sensitivity);
  const warnNose = scaled(0.08, sensitivity);
  const badNose = scaled(0.18, sensitivity);
  const headDown = pitchDelta > scaled(15, sensitivity) && noseDrop < scaled(0.08, sensitivity);
  const forwardHead = noseDrop > scaled(0.08, sensitivity) && pitchDelta > scaled(8, sensitivity);
  const level = levelFromAlert(pitchDelta > warnPitch || noseDrop > warnNose, pitchDelta > badPitch || noseDrop > badNose);
  let label = '下巴高度正常';
  let alertType = PostureAlertType.NONE;
  if (level === PostureLevel.WARN) {
    label = '轻微低头';
  } else if (level === PostureLevel.BAD) {
    label = '低头过久';
  }
  if (headDown) {
    alertType = PostureAlertType.ITEM_03;
    label = level === PostureLevel.BAD ? '低头过久' : '轻微低头';
  } else if (forwardHead) {
    alertType = PostureAlertType.ITEM_05;
    label = level === PostureLevel.BAD ? '脖子前探明显' : '下巴有点前探';
  }
  const pressure = Math.max(pitchDelta, noseDrop * 100);
  return makeMetric(level, face.pitch - profile.neutralPitch, profile.neutralPitch, scoreFromLevel(level, pressure, badPitch), label,
    level === PostureLevel.GOOD ? PostureAlertType.NONE : alertType);
}

function evaluateMouth(face: FaceFrame, profile: CalibrationProfile): MetricResult {
  const sensitivity = Math.max(profile.sensitivity, 0.6);
  if (face.confidence < 0.25) {
    return makeMetric(PostureLevel.UNKNOWN, face.mouthOpenRatio, profile.neutralMouthRatio, 72, '嘴部未识别');
  }
  const openDelta = Math.max(0, face.mouthOpenRatio - profile.neutralMouthRatio);
  const warn = 0.15 / sensitivity;
  const bad = 0.25 / sensitivity;
  const level = levelFromDelta(openDelta, warn, bad);
  let label = '嘴部放松';
  if (level === PostureLevel.WARN) {
    label = '疑似张嘴';
  } else if (level === PostureLevel.BAD) {
    label = '张嘴明显';
  }
  return makeMetric(level, face.mouthOpenRatio, profile.neutralMouthRatio, scoreFromLevel(level, openDelta * 100, bad * 100), label,
    level === PostureLevel.GOOD ? PostureAlertType.NONE : PostureAlertType.ITEM_11);
}

function summaryFor(sit: MetricResult, chin: MetricResult, mouth: MetricResult, score: number): string {
  if (score >= 88) {
    return '坐姿在线';
  }
  if (sit.level === PostureLevel.BAD) {
    return sit.label;
  }
  if (chin.level === PostureLevel.BAD) {
    return chin.label;
  }
  if (mouth.level === PostureLevel.BAD) {
    return mouth.label;
  }
  if (score >= 72) {
    return '稍微调整一下';
  }
  return '坐直了';
}

export function evaluatePosture(sample: PostureSample, profile: CalibrationProfile): PostureResult {
  const sit = evaluateSit(sample.skeleton, sample.face, profile);
  const chin = evaluateChin(sample.face, sample.skeleton, profile);
  const mouth = evaluateMouth(sample.face, profile);
  const score = Math.round(clamp(sit.score * 0.4 + chin.score * 0.45 + mouth.score * 0.15, 0, 100));
  const orderedAlerts = orderedActiveAlerts([sit.alertType, chin.alertType, mouth.alertType]);
  const activeAlerts = orderedAlerts.length > 0 ? [orderedAlerts[0]] : [];
  return {
    timestamp: sample.timestamp,
    sit,
    chin,
    mouth,
    score,
    summary: summaryFor(sit, chin, mouth, score),
    action: ReminderAction.NONE,
    activeAlerts,
    primaryAlert: activeAlerts.length > 0 ? activeAlerts[0] : PostureAlertType.NONE
  };
}
