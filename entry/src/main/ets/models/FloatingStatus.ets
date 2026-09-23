export interface FloatingReading {
  score: number;
  summary: string;
  timestamp: number;
  guarding: boolean;
  foreground: boolean;
  simulated: boolean;
}

export function floatingStatus(reading: FloatingReading, now: number): string {
  if (!reading.foreground) {
    return '已离开应用，检测暂停';
  }
  if (!reading.guarding) {
    return '尚未开始守护';
  }
  if (reading.timestamp <= 0) {
    return '等待首次采样';
  }
  if (now - reading.timestamp > 15000 || reading.timestamp > now) {
    return '采样已中断';
  }
  if (!Number.isFinite(reading.score) || reading.score < 0 || reading.score > 100) {
    return '等待有效评分';
  }
  return reading.simulated ? '模拟数据 · ' + reading.summary : reading.summary;
}

export function floatingScore(reading: FloatingReading, now: number): string {
  return hasFloatingReading(reading, now) ? Math.round(reading.score).toString() : '--';
}

export function hasFloatingReading(reading: FloatingReading, now: number): boolean {
  return reading.guarding && reading.foreground && reading.timestamp > 0 &&
    now >= reading.timestamp && now - reading.timestamp <= 15000 &&
    Number.isFinite(reading.score) && reading.score >= 0 && reading.score <= 100;
}
