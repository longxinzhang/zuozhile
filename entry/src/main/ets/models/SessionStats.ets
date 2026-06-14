import { AlertBreakdownItem, PostureAlertType, PostureLevel, ReminderAction, SessionRecord, TodayStats } from './PostureTypes';

export interface HourBucket {
  label: string;
  score: number;
  badRate: number;
}

const ALERT_PRIORITY: PostureAlertType[] = [
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

export function buildAlertBreakdown(records: SessionRecord[]): AlertBreakdownItem[] {
  const scoped = todayRecords(records).filter((record: SessionRecord) => record.alertType !== PostureAlertType.NONE);
  const total = scoped.length;
  if (total === 0) {
    return [];
  }

  const counts: number[] = ALERT_PRIORITY.map(() => 0);
  scoped.forEach((record: SessionRecord) => {
    const index = ALERT_PRIORITY.indexOf(record.alertType);
    if (index >= 0) {
      counts[index] += 1;
    }
  });

  const items: AlertBreakdownItem[] = [];
  ALERT_PRIORITY.forEach((type: PostureAlertType, index: number) => {
    const count = counts[index];
    if (count > 0) {
      items.push({
        type,
        count,
        percent: Math.round(count * 100 / total)
      });
    }
  });

  return items.sort((left: AlertBreakdownItem, right: AlertBreakdownItem) => {
    if (right.count !== left.count) {
      return right.count - left.count;
    }
    return ALERT_PRIORITY.indexOf(left.type) - ALERT_PRIORITY.indexOf(right.type);
  });
}
