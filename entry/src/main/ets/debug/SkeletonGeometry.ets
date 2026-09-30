export interface DebugJoint extends DebugPoint {
  type: number;
  x: number;
  y: number;
  confidence: number;
}

export interface DebugPoint {
  x: number;
  y: number;
}

export interface DebugBone {
  start: DebugPoint;
  end: DebugPoint;
  side: number;
}

export interface DebugDrawing {
  joints: DebugPoint[];
  bones: DebugBone[];
}

// Core Vision's 17-point ordering. Confidence filtering here affects drawing only.
export const DEBUG_POINT_CONFIDENCE = 0.35;
const CONNECTIONS: number[][] = [[0, 1], [0, 2], [1, 3], [2, 4], [3, 5], [4, 6],
  [5, 6], [5, 7], [7, 9], [6, 8], [8, 10], [5, 11], [6, 12], [11, 12],
  [11, 13], [13, 15], [12, 14], [14, 16]];

export function visibleJoints(points: DebugJoint[], width: number, height: number): DebugJoint[] {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return [];
  }
  const result: DebugJoint[] = [];
  points.forEach((point: DebugJoint) => {
    if (!Number.isInteger(point.type) || point.type < 0 || point.type > 16 ||
      !Number.isFinite(point.x) || !Number.isFinite(point.y) || !Number.isFinite(point.confidence) ||
      point.confidence < DEBUG_POINT_CONFIDENCE || point.confidence > 1 ||
      point.x < 0 || point.x > width || point.y < 0 || point.y > height) {
      return;
    }
    const existing = result.findIndex((item: DebugJoint) => item.type === point.type);
    if (existing < 0) {
      result.push({ type: point.type, x: point.x, y: point.y, confidence: point.confidence });
    } else if (point.confidence > result[existing].confidence) {
      result[existing] = { type: point.type, x: point.x, y: point.y, confidence: point.confidence };
    }
  });
  return result;
}

export function projectJoint(point: DebugPoint, width: number, height: number,
  viewportWidth: number, viewportHeight: number, mirrored: boolean): DebugPoint {
  const scale = Math.min(viewportWidth / width, viewportHeight / height);
  const x = (viewportWidth - width * scale) / 2 + point.x * scale;
  return { x: mirrored ? viewportWidth - x : x,
    y: (viewportHeight - height * scale) / 2 + point.y * scale };
}

export function skeletonDrawing(points: DebugJoint[], width: number, height: number,
  viewportWidth: number, viewportHeight: number, mirrored: boolean): DebugDrawing {
  if (![width, height, viewportWidth, viewportHeight].every((value: number) =>
    Number.isFinite(value) && value > 0)) {
    return { joints: [], bones: [] };
  }
  const visible = visibleJoints(points, width, height);
  const bones: DebugBone[] = [];
  CONNECTIONS.forEach((connection: number[]) => {
    const start = visible.find((point: DebugJoint) => point.type === connection[0]);
    const end = visible.find((point: DebugJoint) => point.type === connection[1]);
    if (start && end) {
      bones.push({ start: projectJoint(start, width, height, viewportWidth, viewportHeight, mirrored),
        end: projectJoint(end, width, height, viewportWidth, viewportHeight, mirrored),
        side: connection[1] % 2 });
    }
  });
  return { joints: visible.map((point: DebugJoint) =>
    projectJoint(point, width, height, viewportWidth, viewportHeight, mirrored)), bones };
}
