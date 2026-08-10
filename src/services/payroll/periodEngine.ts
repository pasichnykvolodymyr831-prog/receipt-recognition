import payrollSchedule from "../../assets/schema/payrollSchedule.json";
import type { PayPeriod, TimesheetRowEntry } from "../../types/models";

interface ScheduleEntry {
  startDate: string;
  endDate: string;
  dueDateTime: string | null;
  dueDateTimeIfWorkingWeekend: string | null;
  statHolidays: { label: string; date: string }[];
}

const SCHEDULE: ScheduleEntry[] = payrollSchedule.periods;
const SCHEDULE_BY_START = new Map(SCHEDULE.map((p) => [p.startDate, p]));

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

export function toIsoDate(date: Date): string {
  return `${date.getFullYear()}-${pad2(date.getMonth() + 1)}-${pad2(date.getDate())}`;
}

export function fromIsoDate(iso: string): Date {
  const [y, m, d] = iso.split("-").map(Number);
  return new Date(y, m - 1, d);
}

/**
 * The company's fixed semi-monthly cycle, verified against every real row
 * in Payroll_Dates: each period runs either the 9th-23rd, or the 24th
 * through the 8th of the following month.
 */
export function getPeriodBoundaries(date: Date): { startDate: string; endDate: string } {
  const y = date.getFullYear();
  const m = date.getMonth();
  const day = date.getDate();

  if (day >= 9 && day <= 23) {
    return { startDate: toIsoDate(new Date(y, m, 9)), endDate: toIsoDate(new Date(y, m, 23)) };
  }
  if (day >= 24) {
    return { startDate: toIsoDate(new Date(y, m, 24)), endDate: toIsoDate(new Date(y, m + 1, 8)) };
  }
  // day 1-8: belongs to the period that started on the 24th of the previous month.
  return { startDate: toIsoDate(new Date(y, m - 1, 24)), endDate: toIsoDate(new Date(y, m, 8)) };
}

function fallbackDueDateTime(endDate: string): string {
  return `${endDate}T16:30:00`;
}

export function resolvePeriod(startDate: string, endDate: string): PayPeriod {
  const known = SCHEDULE_BY_START.get(startDate);
  if (known) {
    return {
      startDate: known.startDate,
      endDate: known.endDate,
      dueDateTime: known.dueDateTime,
      dueDateTimeIfWorkingWeekend: known.dueDateTimeIfWorkingWeekend,
      statHolidayDates: known.statHolidays.map((h) => h.date),
      isGenerated: false,
    };
  }
  // Outside the bundled company calendar (see scripts/extract-payroll-schedule.js) -
  // best-effort default: period end at 4:30pm, no known STAT days.
  return {
    startDate,
    endDate,
    dueDateTime: fallbackDueDateTime(endDate),
    dueDateTimeIfWorkingWeekend: null,
    statHolidayDates: [],
    isGenerated: true,
  };
}

export function getPeriodForDate(date: Date): PayPeriod {
  const { startDate, endDate } = getPeriodBoundaries(date);
  return resolvePeriod(startDate, endDate);
}

export function getCurrentPeriod(now: Date = new Date()): PayPeriod {
  return getPeriodForDate(now);
}

export function isWeekend(dateIso: string): boolean {
  const day = fromIsoDate(dateIso).getDay();
  return day === 0 || day === 6;
}

export function isStatHoliday(dateIso: string, period: PayPeriod): boolean {
  return period.statHolidayDates.includes(dateIso);
}

/**
 * The due date/time to actually show the user: if the primary deadline
 * falls on a weekend, the company's calendar gives an alternate Monday
 * date/time for the "if working weekend" case.
 */
export function effectiveDueDateTime(period: PayPeriod): string | null {
  if (!period.dueDateTime) return null;
  const dueDate = new Date(period.dueDateTime);
  const dueIsWeekend = dueDate.getDay() === 0 || dueDate.getDay() === 6;
  if (dueIsWeekend && period.dueDateTimeIfWorkingWeekend) {
    return period.dueDateTimeIfWorkingWeekend;
  }
  return period.dueDateTime;
}

export function isDeadlineApproaching(period: PayPeriod, now: Date = new Date()): boolean {
  const due = effectiveDueDateTime(period);
  if (!due) return false;
  const msRemaining = new Date(due).getTime() - now.getTime();
  const oneDayMs = 24 * 60 * 60 * 1000;
  return msRemaining > 0 && msRemaining <= oneDayMs;
}

/** Every calendar date in [startDate, endDate], inclusive, as ISO strings. */
export function listPeriodDates(period: PayPeriod): string[] {
  const dates: string[] = [];
  let cursor = fromIsoDate(period.startDate);
  const end = fromIsoDate(period.endDate);
  while (cursor <= end) {
    dates.push(toIsoDate(cursor));
    cursor = new Date(cursor.getFullYear(), cursor.getMonth(), cursor.getDate() + 1);
  }
  return dates;
}

const DEFAULT_START_MINUTES = 8 * 60; // 8:00
const DEFAULT_LUNCH_DURATION_MINUTES = 30; // 12:00-12:30
const DEFAULT_FINISH_MINUTES = 16 * 60 + 30; // 16:30

/**
 * Default Timesheet rows for a period: weekdays get the standard 8:00 /
 * 30-min lunch / 16:30 shift, weekends and STAT-holiday weekdays stay blank.
 */
export function generateDefaultTimesheetRows(period: PayPeriod): TimesheetRowEntry[] {
  return listPeriodDates(period).map((date) => {
    if (isWeekend(date) || isStatHoliday(date, period)) {
      return { date, startMinutes: null, lunchBreakMinutes: null, coffeeBreakMinutes: null, finishMinutes: null };
    }
    return {
      date,
      startMinutes: DEFAULT_START_MINUTES,
      lunchBreakMinutes: DEFAULT_LUNCH_DURATION_MINUTES,
      coffeeBreakMinutes: null,
      finishMinutes: DEFAULT_FINISH_MINUTES,
    };
  });
}
