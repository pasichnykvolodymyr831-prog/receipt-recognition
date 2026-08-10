import timesheetSchema from "../../assets/schema/timesheet.json";
import { TIMESHEET_TEMPLATE_MODULE } from "../../assets/templates";
import type { Employee, PayPeriod, TimesheetRowEntry } from "../../types/models";
import { fromIsoDate } from "../../utils/isoDate";
import { dateToExcelSerial } from "./excelDates";
import { setCellFormula, setCellInlineString, setCellNumber } from "./ooxml";
import { openTemplateDocument, workingCopyUri } from "./templateAccess";

const MONTH_ABBREV = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

/** Matches the sample's own label style, e.g. "Jul 24 - Aug 07 2026". */
function formatPayPeriodLabel(period: PayPeriod): string {
  const start = fromIsoDate(period.startDate);
  const end = fromIsoDate(period.endDate);
  return `${MONTH_ABBREV[start.getMonth()]} ${start.getDate()} - ${MONTH_ABBREV[end.getMonth()]} ${pad2(
    end.getDate()
  )} ${end.getFullYear()}`;
}

function minutesToExcelFraction(minutesAfterMidnight: number): number {
  return minutesAfterMidnight / 1440;
}

/**
 * The template already has an "h:mm" number format on the Start Time (C)
 * and Finish Time (F) columns' cells - the sample file just happened to
 * hold free text ("8am") there instead of a real time value, so the
 * format was never exercised. The Lunch/Coffee Break columns (D/E) don't
 * have a time format of their own, so they deliberately borrow Start
 * Time's style (also "h:mm") rather than getting a new style added.
 */
const DURATION_COLUMN_STYLE_ID = "18"; // = Start Time column's own template style id

export interface WriteTimesheetParams {
  employee: Employee;
  period: PayPeriod;
  rows: TimesheetRowEntry[]; // one entry per calendar day of the period, in order
}

/** Regenerates this period's Timesheet working copy from the pristine template and returns its file URI. */
export async function writeTimesheetWorkingCopy({ employee, period, rows }: WriteTimesheetParams): Promise<string> {
  const schema = timesheetSchema;
  const doc = await openTemplateDocument(TIMESHEET_TEMPLATE_MODULE);
  let xml = await doc.getSheetXml(schema.sheetName);

  xml = setCellInlineString(xml, schema.employeeNameCell, employee.fullName);
  xml = setCellInlineString(xml, schema.employeePhoneCell, employee.phone);
  xml = setCellInlineString(xml, schema.payPeriodCell, formatPayPeriodLabel(period));

  const maxRows = schema.dataRowEnd - schema.dataRowStart + 1;
  if (rows.length > maxRows) {
    throw new Error(
      `This pay period has ${rows.length} days, but the Timesheet template only has room for ${maxRows}.`
    );
  }

  let totalMinutes = 0;
  rows.forEach((row, index) => {
    const rowNum = schema.dataRowStart + index;
    const c = schema.columns;

    xml = setCellNumber(xml, `${c.date}${rowNum}`, dateToExcelSerial(fromIsoDate(row.date)));

    const hasEntry = row.startMinutes !== null && row.finishMinutes !== null;
    if (!hasEntry) return; // blank row (weekend/STAT/not filled) - leave Start..Total empty

    const start = row.startMinutes as number;
    const finish = row.finishMinutes as number;
    const lunch = row.lunchBreakMinutes ?? 0;
    const coffee = row.coffeeBreakMinutes ?? 0;

    xml = setCellNumber(xml, `${c.startTime}${rowNum}`, minutesToExcelFraction(start));
    xml = setCellNumber(xml, `${c.finishTime}${rowNum}`, minutesToExcelFraction(finish));
    if (row.lunchBreakMinutes !== null) {
      xml = setCellNumber(xml, `${c.lunchBreak}${rowNum}`, minutesToExcelFraction(lunch), {
        styleId: DURATION_COLUMN_STYLE_ID,
      });
    }
    if (row.coffeeBreakMinutes !== null) {
      xml = setCellNumber(xml, `${c.coffeeBreak}${rowNum}`, minutesToExcelFraction(coffee), {
        styleId: DURATION_COLUMN_STYLE_ID,
      });
    }

    const hoursValue = Math.max(0, (finish - start - lunch - coffee) / 60);
    const hoursFormula = `(${c.finishTime}${rowNum}-${c.startTime}${rowNum}-${c.lunchBreak}${rowNum}-${c.coffeeBreak}${rowNum})*24`;
    xml = setCellFormula(xml, `${c.hours}${rowNum}`, hoursFormula, hoursValue);
    xml = setCellFormula(xml, `${c.total}${rowNum}`, `${c.hours}${rowNum}`, hoursValue);
    totalMinutes += hoursValue * 60;
  });

  xml = setCellFormula(
    xml,
    schema.totalHoursValueCell,
    `SUM(${schema.columns.hours}${schema.dataRowStart}:${schema.columns.hours}${schema.dataRowEnd})`,
    totalMinutes / 60
  );

  doc.setSheetXml(schema.sheetName, xml);

  const destUri = workingCopyUri(period.startDate, "Timesheet");
  await doc.saveToUri(destUri);
  return destUri;
}
