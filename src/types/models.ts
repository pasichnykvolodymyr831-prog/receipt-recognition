import type { CompanyId } from "../config/companies";

export interface Employee {
  fullName: string;
  phone: string;
}

/** Matches the options in Settings -> "Хранение истории периодов". */
export type RetentionPolicy = "1m" | "3m" | "6m" | "1y" | "forever" | "none";

export const DEFAULT_RETENTION_POLICY: RetentionPolicy = "3m";

export type AppLanguage = "ru" | "en";

export interface AppSettings {
  language: AppLanguage;
  employee: Employee;
  retentionPolicy: RetentionPolicy;
  defaultCompanyId: CompanyId;
}

/** A resolved pay period: calendar boundaries + (when known) real deadline/STAT data. */
export interface PayPeriod {
  /** ISO yyyy-mm-dd - also used as the storage key for this period's data. */
  startDate: string;
  endDate: string;
  dueDateTime: string | null;
  dueDateTimeIfWorkingWeekend: string | null;
  statHolidayDates: string[];
  /**
   * True when this period falls outside the bundled payroll schedule
   * (see src/assets/schema/payrollSchedule.json) and its due date/STAT
   * days had to be guessed (period end at 4:30pm, no known STAT days)
   * rather than read from the company's real calendar.
   */
  isGenerated: boolean;
}

/** One calendar day's row in the Timesheet. Null fields = blank row (weekend/STAT/not yet filled). */
export interface TimesheetRowEntry {
  date: string; // ISO yyyy-mm-dd
  startMinutes: number | null; // minutes after midnight
  lunchBreakMinutes: number | null; // duration in minutes
  coffeeBreakMinutes: number | null; // duration in minutes
  finishMinutes: number | null; // minutes after midnight
}

interface ExpenseEntryBase {
  id: string;
  companyId: CompanyId;
  date: string; // ISO yyyy-mm-dd
  description: string;
  createdAt: string; // ISO datetime
}

export interface ReceiptExpenseEntry extends ExpenseEntryBase {
  kind: "receipt";
  /** Matches a categoryColumns[].key from src/assets/schema/expenseReport.json for this company. */
  categoryKey: string;
  netBeforeGst: number;
  gst: number;
  vendorNameRaw?: string;
}

export interface KilometersExpenseEntry extends ExpenseEntryBase {
  kind: "kilometers";
  km: number;
  ratePerKm: number;
  amount: number; // km * ratePerKm, placed into the Auto/Travel-style category column
}

export type ExpenseEntry = ReceiptExpenseEntry | KilometersExpenseEntry;

export interface DrivingDetailEntry {
  id: string;
  date: string; // ISO yyyy-mm-dd
  trip: string;
  km: number;
  createdAt: string; // ISO datetime
}

export interface PeriodData {
  periodKey: string; // = PayPeriod.startDate
  timesheet: TimesheetRowEntry[];
  expensesByCompany: Partial<Record<CompanyId, ExpenseEntry[]>>;
  drivingDetails: DrivingDetailEntry[];
}

export function emptyPeriodData(periodKey: string): PeriodData {
  return { periodKey, timesheet: [], expensesByCompany: {}, drivingDetails: [] };
}
