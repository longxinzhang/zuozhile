import { CalibrationProfile, FaceFrame, Point2D, PostureSample, SkeletonFrame } from '../models/PostureTypes';

function shoulderPoint(x: number, y: number): Point2D {
  return {
    x,
    y,
    score: 0.95
  };
}

function skeletonFromAngles(neckAngle: number, tiltRatio: number, shoulderWidthRatio: number, bodyDrop: number): SkeletonFrame {
  const shoulderMidX = 180;
  const shoulderMidY = 360 + bodyDrop;
  const shoulderWidth = 180 * shoulderWidthRatio;
  const headDistance = 158;
  const tiltPixels = shoulderWidth * tiltRatio;
  const radians = neckAngle * Math.PI / 180;
  const nose: Point2D = {
    x: shoulderMidX + Math.tan(radians) * headDistance,
    y: shoulderMidY - headDistance,
    score: 0.96
  };
  return {
    nose,
    leftEar: shoulderPoint(nose.x - 42, nose.y + 12),
    rightEar: shoulderPoint(nose.x + 42, nose.y + 12),
    leftShoulder: shoulderPoint(shoulderMidX - shoulderWidth / 2, shoulderMidY - tiltPixels / 2),
    rightShoulder: shoulderPoint(shoulderMidX + shoulderWidth / 2, shoulderMidY + tiltPixels / 2),
    leftHip: shoulderPoint(shoulderMidX - 70, shoulderMidY + 176),
    rightHip: shoulderPoint(shoulderMidX + 70, shoulderMidY + 170)
  };
}

function faceFromPose(pitch: number, roll: number, mouthOpenRatio: number, faceTop: number, faceScale: number): FaceFrame {
  const width = 96 * faceScale;
  const height = 120 * faceScale;
  return {
    yaw: 0,
    pitch,
    roll,
    mouthOpenRatio,
    confidence: 0.95,
    rect: {
      left: 132 - width / 2,
      top: faceTop,
      width,
      height
    }
  };
}

export function createSimulatedSample(tick: number, profile: CalibrationProfile): PostureSample {
  const phase = tick % 14;
  let neckAngle = profile.neutralNeckAngle + 2;
  let tiltRatio = profile.neutralShoulderTilt + 0.01;
  let pitch = profile.neutralPitch + 1;
  let roll = profile.neutralRoll;
  let mouth = profile.neutralMouthRatio + 0.03;
  let shoulderWidthRatio = 1;
  let bodyDrop = 0;
  let faceTop = 120;
  let faceScale = 1;

  if (phase >= 5 && phase <= 7) {
    neckAngle = profile.neutralNeckAngle + 10 + phase;
    pitch = profile.neutralPitch - 10;
    mouth = profile.neutralMouthRatio + 0.1;
  } else if (phase >= 8 && phase <= 11) {
    neckAngle = profile.neutralNeckAngle + 20 + phase;
    tiltRatio = profile.neutralShoulderTilt + 0.16;
    pitch = profile.neutralPitch - 22;
    roll = profile.neutralRoll + 12;
    mouth = profile.neutralMouthRatio + 0.28;
    shoulderWidthRatio = 0.82;
    faceScale = 1.2;
  } else if (phase === 12) {
    neckAngle = profile.neutralNeckAngle + 12;
    tiltRatio = profile.neutralShoulderTilt + 0.08;
    pitch = profile.neutralPitch - 6;
    mouth = profile.neutralMouthRatio + 0.08;
    bodyDrop = 42;
    faceTop = 160;
  }

  return {
    timestamp: Date.now(),
    skeleton: skeletonFromAngles(neckAngle, tiltRatio, shoulderWidthRatio, bodyDrop),
    face: faceFromPose(pitch, roll, mouth, faceTop, faceScale)
  };
}
