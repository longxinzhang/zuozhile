export class EdgeGlowPoint {
  x: number;
  y: number;

  constructor(x: number, y: number) {
    this.x = x;
    this.y = y;
  }
}

export class EdgeGlowWedge {
  start: EdgeGlowPoint;
  end: EdgeGlowPoint;
  points: EdgeGlowPoint[];

  constructor(start: EdgeGlowPoint, end: EdgeGlowPoint, points: EdgeGlowPoint[]) {
    this.start = start;
    this.end = end;
    this.points = points;
  }
}

export class EdgeGlowStop {
  offset: number;
  alpha: number;

  constructor(offset: number, alpha: number) {
    this.offset = offset;
    this.alpha = alpha;
  }
}

export function edgeGlowWedges(width: number, height: number): EdgeGlowWedge[] {
  if (!Number.isFinite(width) || !Number.isFinite(height) || width <= 0 || height <= 0) {
    return [];
  }
  const center = new EdgeGlowPoint(width / 2, height / 2);
  const topLeft = new EdgeGlowPoint(0, 0);
  const topRight = new EdgeGlowPoint(width, 0);
  const bottomLeft = new EdgeGlowPoint(0, height);
  const bottomRight = new EdgeGlowPoint(width, height);
  return [
    new EdgeGlowWedge(new EdgeGlowPoint(width / 2, 0), center, [topLeft, topRight, center]),
    new EdgeGlowWedge(new EdgeGlowPoint(width, height / 2), center, [topRight, bottomRight, center]),
    new EdgeGlowWedge(new EdgeGlowPoint(width / 2, height), center, [bottomRight, bottomLeft, center]),
    new EdgeGlowWedge(new EdgeGlowPoint(0, height / 2), center, [bottomLeft, topLeft, center])
  ];
}

export function edgeGlowStops(strong: boolean): EdgeGlowStop[] {
  const intensity = strong ? 0.76 : 0.58;
  return [
    new EdgeGlowStop(0, intensity),
    new EdgeGlowStop(0.08, intensity * 0.82),
    new EdgeGlowStop(0.2, intensity * 0.48),
    new EdgeGlowStop(0.45, intensity * 0.14),
    new EdgeGlowStop(0.72, intensity * 0.025),
    new EdgeGlowStop(1, 0)
  ];
}
