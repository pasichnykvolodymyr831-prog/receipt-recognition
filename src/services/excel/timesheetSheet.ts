import timesheetSchema from "../../assets/schema/timesheet.json";
import type { Employee, PayPeriod, TimesheetRowEntry } from "../../types/models";
import { fromIsoDate } from "../../utils/isoDate";
import { formatPayPeriodLabel } from "../../utils/payPeriodLabel";
import { dateToExcelSerial } from "./excelDates";
import { clearCell, setCellFormula, setCellInlineString, setCellNumber } from "./ooxml";

/**
 * Pure Timesheet sheet-XML writer - no expo-asset/expo-file-system imports,
 * so it can be exercised directly against the real template from plain
 * Node (see scripts/verify-timesheet-writer.mjs). The RN-facing
 * orchestrator that opens/saves the bundled template asset lives in
 * timesheetWriter.ts.
 */

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

export function writeTimesheetSheet(
  xml: string,
  employee: Employee,
  period: PayPeriod,
  rows: TimesheetRowEntry[]
): string {
  const schema = timesheetSchema;
  let next = xml;

  next = setCellInlineString(next, schema.employeeNameCell, employee.fullName);
  next = setCellInlineString(next, schema.employeePhoneCell, employee.phone);
  next = setCellInlineString(next, schema.payPeriodCell, formatPayPeriodLabel(period));

  const maxRows = schema.dataRowEnd - schema.dataRowStart + 1;
  if (rows.length > maxRows) {
    throw new Error(
      `This pay period has ${rows.length} days, but the Timesheet template only has room for ${maxRows}.`
    );
  }

  const c = schema.columns;
  // The bundled "template" is actually a filled sample report (a real
  // employee's past period), not a blank canonical form. A different
  // period's weekends/STAT days land on different row numbers and shorter
  // periods don't fill every row, so without this, leftover sample dates/
  // times/hours from rows we never write to would leak into the output.
  for (let rowNum = schema.dataRowStart; rowNum <= schema.dataRowEnd; rowNum++) {
    next = clearCell(next, `${c.date}${rowNum}`);
    next = clearCell(next, `${c.startTime}${rowNum}`);
    next = clearCell(next, `${c.lunchBreak}${rowNum}`);
    next = clearCell(next, `${c.coffeeBreak}${rowNum}`);
    next = clearCell(next, `${c.finishTime}${rowNum}`);
    next = clearCell(next, `${c.hours}${rowNum}`);
    next = clearCell(next, `${c.total}${rowNum}`);
  }

  let totalMinutes = 0;
  rows.forEach((row, index) => {
    const rowNum = schema.dataRowStart + index;

    next = setCellNumber(next, `${c.date}${rowNum}`, dateToExcelSerial(fromIsoDate(row.date)));

    const hasEntry = row.startMinutes !== null && row.finishMinutes !== null;
    if (!hasEntry) return; // blank row (weekend/STAT/not filled) - leave Start..Total empty

    const start = row.startMinutes as number;
    const finish = row.finishMinutes as number;
    const lunch = row.lunchBreakMinutes ?? 0;
    const coffee = row.coffeeBreakMinutes ?? 0;

    next = setCellNumber(next, `${c.startTime}${rowNum}`, minutesToExcelFraction(start));
    next = setCellNumber(next, `${c.finishTime}${rowNum}`, minutesToExcelFraction(finish));
    if (row.lunchBreakMinutes !== null) {
      next = setCellNumber(next, `${c.lunchBreak}${rowNum}`, minutesToExcelFraction(lunch), {
        styleId: DURATION_COLUMN_STYLE_ID,
      });
    }
    if (row.coffeeBreakMinutes !== null) {
      next = setCellNumber(next, `${c.coffeeBreak}${rowNum}`, minutesToExcelFraction(coffee), {
        styleId: DURATION_COLUMN_STYLE_ID,
      });
    }

    const hoursValue = Math.max(0, (finish - start - lunch - coffee) / 60);
    const hoursFormula = `(${c.finishTime}${rowNum}-${c.startTime}${rowNum}-${c.lunchBreak}${rowNum}-${c.coffeeBreak}${rowNum})*24`;
    next = setCellFormula(next, `${c.hours}${rowNum}`, hoursFormula, hoursValue);
    next = setCellFormula(next, `${c.total}${rowNum}`, `${c.hours}${rowNum}`, hoursValue);
    totalMinutes += hoursValue * 60;
  });

  next = setCellFormula(
    next,
    schema.totalHoursValueCell,
    `SUM(${schema.columns.hours}${schema.dataRowStart}:${schema.columns.hours}${schema.dataRowEnd})`,
    totalMinutes / 60
  );

  return next;
}
