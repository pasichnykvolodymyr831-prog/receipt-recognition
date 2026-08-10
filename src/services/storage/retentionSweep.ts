import type { RetentionPolicy } from "../../types/models";
import { fromIsoDate, toIsoDate } from "../payroll/periodEngine";
import { deletePeriodData, listStoredPeriodKeys } from "./periodDataRepository";

/** Months of history to keep after a period ends; 'none' keeps nothing once a period is over. */
const RETENTION_MONTHS: Record<RetentionPolicy, number> = {
  none: 0,
  "1m": 1,
  "3m": 3,
  "6m": 6,
  "1y": 12,
  forever: Number.POSITIVE_INFINITY,
};

function addMonths(date: Date, months: number): Date {
  return new Date(date.getFullYear(), date.getMonth() + months, date.getDate());
}

/**
 * A stored period should be deleted once `retention` months have passed
 * since it ended. `periodEndDate` is that period's own end date, not the
 * period's storage key (which is its start date) - a period is only
 * ever "old" relative to when it finished, not when it began.
 */
export function isPeriodExpired(periodEndDateIso: string, retention: RetentionPolicy, now: Date = new Date()): boolean {
  const months = RETENTION_MONTHS[retention];
  if (!Number.isFinite(months)) return false; // 'forever'
  const expiryDate = addMonths(fromIsoDate(periodEndDateIso), months);
  return toIsoDate(expiryDate) < toIsoDate(now);
}

/**
 * Deletes stored period data older than the configured retention policy.
 * Meant to run once at app start. Only ever removes the app's own working
 * copy (AsyncStorage JSON + any regenerated .xlsx in the app's document
 * directory) - files the user already shared/saved elsewhere are untouched.
 */
export async function sweepExpiredPeriods(retention: RetentionPolicy, now: Date = new Date()): Promise<string[]> {
  const periodKeys = await listStoredPeriodKeys();
  const removed: string[] = [];
  for (const periodKey of periodKeys) {
    // periodKey is the period's startDate; approximate its end date via the
    // same semi-monthly rule used everywhere else (9-23 or 24-8).
    const day = fromIsoDate(periodKey).getDate();
    const endDate =
      day === 9
        ? toIsoDate(new Date(fromIsoDate(periodKey).getFullYear(), fromIsoDate(periodKey).getMonth(), 23))
        : toIsoDate(
            new Date(fromIsoDate(periodKey).getFullYear(), fromIsoDate(periodKey).getMonth() + 1, 8)
          );

    if (isPeriodExpired(endDate, retention, now)) {
      await deletePeriodData(periodKey);
      removed.push(periodKey);
    }
  }
  return removed;
}
