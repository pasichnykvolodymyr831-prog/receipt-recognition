import timesheetSchema from "../../assets/schema/timesheet.json";
import { TIMESHEET_TEMPLATE_MODULE } from "../../assets/templates";
import type { Employee, PayPeriod, TimesheetRowEntry } from "../../types/models";
import { writeTimesheetSheet } from "./timesheetSheet";
import { openTemplateDocument, workingCopyUri } from "./templateAccess";

export interface WriteTimesheetParams {
  employee: Employee;
  period: PayPeriod;
  rows: TimesheetRowEntry[]; // one entry per calendar day of the period, in order
}

/** Regenerates this period's Timesheet working copy from the pristine template and returns its file URI. */
export async function writeTimesheetWorkingCopy({ employee, period, rows }: WriteTimesheetParams): Promise<string> {
  const doc = await openTemplateDocument(TIMESHEET_TEMPLATE_MODULE);
  const xml = await doc.getSheetXml(timesheetSchema.sheetName);
  doc.setSheetXml(timesheetSchema.sheetName, writeTimesheetSheet(xml, employee, period, rows));

  const destUri = workingCopyUri(period.startDate, "Timesheet");
  await doc.saveToUri(destUri);
  return destUri;
}
