/**
 * Conversions between JS Date/time-of-day and Excel's 1900-date-system
 * serial numbers, matching what Excel/Google Sheets and the `xlsx`
 * package itself use (verified against real serials in the templates,
 * e.g. serial 46227 = 2026-07-24).
 */

// Dec 30 1899 as "day 0" reproduces Excel's (Lotus 1-2-3 compatible)
// serial numbers, including the fictitious Feb 29 1900, for every real
// date this app will ever handle (all dates are >= 1900-03-01).
const EXCEL_EPOCH_UTC_MS = Date.UTC(1899, 11, 30);
const MS_PER_DAY = 86400000;

/** Local calendar date -> Excel date serial (whole number, no time-of-day part). */
export function dateToExcelSerial(date: Date): number {
  const localMidnightUtcMs = Date.UTC(date.getFullYear(), date.getMonth(), date.getDate());
  return Math.round((localMidnightUtcMs - EXCEL_EPOCH_UTC_MS) / MS_PER_DAY);
}

export function excelSerialToDate(serial: number): Date {
  const ms = EXCEL_EPOCH_UTC_MS + serial * MS_PER_DAY;
  const d = new Date(ms);
  return new Date(d.getUTCFullYear(), d.getUTCMonth(), d.getUTCDate());
}

/** 08:00 -> 0.3333..., as a fraction of a day - the OOXML representation of a time-of-day. */
export function timeOfDayToExcelFraction(hours: number, minutes: number): number {
  return (hours * 60 + minutes) / 1440;
}

/** A duration in minutes (e.g. a 30-minute lunch break) as a fraction of a day. */
export function durationMinutesToExcelFraction(minutes: number): number {
  return minutes / 1440;
}

export function excelFractionToMinutesOfDay(fraction: number): number {
  return Math.round(fraction * 1440);
}
