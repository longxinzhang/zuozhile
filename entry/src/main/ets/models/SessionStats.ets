import { PostureLevel, ReminderAction, SessionRecord, TodayStats } from './PostureTypes';

export interface HourBucket {
  label: string;
  score: number;
  badRate: number;
}

function sameDay(left: number, right: number): boolean {
  const a = new Date(left);
  const b = new Date(right);
  return a.getFullYear() === b.getFullYear() && a.getMonth() === b.getMonth() && a.getDate() === b.getDate();
}

export function todayRecords(records: SessionRecord[]): SessionRecord[] {
  const now = Date.now();
  return records.filter((record: SessionRecord) => sameDay(record.timestamp, now));
}

export function computeTodayStats(records: SessionRecord[], sampleIntervalMs: number): TodayStats {
  const scoped = todayRecords(records);
  let scoreTotal = 0;
  let uprightCount = 0;
  let warnCount = 0;
  let badCount = 0;
  let remindCount = 0;
  scoped.forEach((record: SessionRecord) => {
    scoreTotal += record.score;
    if (record.sitLevel === PostureLevel.BAD || record.chinLevel === PostureLevel.BAD) {
      badCount += 1;
    } else if (record.sitLevel === PostureLevel.WARN || record.chinLevel === PostureLevel.WARN ||
      record.mouthLevel === PostureLevel.WARN) {
      warnCount += 1;
    } else {
      uprightCount += 1;
    }
    if (record.action !== ReminderAction.NONE) {
      remindCount += 1;
    }
  });

  const sampleCount = scoped.length;
  const averageScore = sampleCount > 0 ? Math.round(scoreTotal / sampleCount) : 0;
  const minutesPerSample = sampleIntervalMs / 60000;
  return {
    sampleCount,
    uprightCount,
    warnCount,
    badCount,
    remindCount,
    averageScore,
    guardedMinutes: Math.round(sampleCount * minutesPerSample),
    uprightMinutes: Math.round(uprightCount * minutesPerSample)
  };
}

export function buildRecentBuckets(records: SessionRecord[]): HourBucket[] {
  const scoped = todayRecords(records);
  const nowHour = new Date().getHours();
  const buckets: HourBucket[] = [];
  for (let offset = 5; offset >= 0; offset -= 1) {
    const hour = (nowHour - offset + 24) % 24;
    const recordsInHour = scoped.filter((record: SessionRecord) => new Date(record.timestamp).getHours() === hour);
    let scoreTotal = 0;
    let badCount = 0;
    recordsInHour.forEach((record: SessionRecord) => {
      scoreTotal += record.score;
      if (record.sitLevel === PostureLevel.BAD || record.chinLevel === PostureLevel.BAD) {
        badCount += 1;
      }
    });
    const count = recordsInHour.length;
    buckets.push({
      label: hour.toString().padStart(2, '0') + ':00',
      score: count > 0 ? Math.round(scoreTotal / count) : 0,
      badRate: count > 0 ? Math.round(badCount * 100 / count) : 0
    });
  }
  return buckets;
}
