import drivingSchema from "../../assets/schema/drivingDetails.json";
import expenseSchema from "../../assets/schema/expenseReport.json";
import type { DrivingDetailEntry, Employee, ExpenseEntry, PayPeriod } from "../../types/models";
import { fromIsoDate } from "../../utils/isoDate";
import { formatPayPeriodLabel } from "../../utils/payPeriodLabel";
import { dateToExcelSerial } from "./excelDates";
import { clearCell, setCellFormula, setCellInlineString, setCellNumber } from "./ooxml";

/**
 * Pure sheet-XML writers for the Expense Report / Mileage Report workbook -
 * no expo-asset/expo-file-system imports, so this module can also be
 * exercised directly against the real template from plain Node (see
 * scripts/verify-expense-writer.mjs). The RN-facing orchestrator that
 * actually opens/saves the bundled template asset lives in
 * expenseReportWriter.ts.
 */

export type CompanySchema = (typeof expenseSchema.companies)[number];

export function findCompanySchema(sheetName: string): CompanySchema {
  const found = expenseSchema.companies.find((c) => c.sheetName === sheetName);
  if (!found) throw new Error(`No Expense Report schema for sheet "${sheetName}"`);
  return found;
}

/** The category column to put a Kilometers claim's amount into - the one that reads like "Auto"/"Travel". */
export function findMileageCategoryColumn(schema: CompanySchema): CompanySchema["categoryColumns"][number] | null {
  return schema.categoryColumns.find((c) => /auto|travel/i.test(c.label)) ?? null;
}

/**
 * A photographed receipt is overwhelmingly a materials/goods purchase, so
 * for companies that have a "Materials" column it's a sensible pre-fill
 * for the confirm screen's category picker - never auto-saved, always
 * still an editable choice.
 */
export function findMaterialsCategoryKey(schema: CompanySchema): string {
  return schema.categoryColumns.find((c) => /materials/i.test(c.label))?.key ?? "";
}

export class CapacityError extends Error {}

export function writeCompanySheet(
  xml: string,
  schema: CompanySchema,
  employee: Employee,
  period: PayPeriod,
  entries: ExpenseEntry[]
): string {
  let next = xml;
  next = setCellInlineString(next, `B3`, employee.fullName);
  next = setCellInlineString(next, `M3`, formatPayPeriodLabel(period));

  const receipts = entries.filter((e): e is Extract<ExpenseEntry, { kind: "receipt" }> => e.kind === "receipt");
  const kilometers = entries.filter((e): e is Extract<ExpenseEntry, { kind: "kilometers" }> => e.kind === "kilometers");
  const capacity = schema.dataRowEnd - schema.dataRowStart + 1;
  const rowsNeeded = receipts.length + (kilometers.length > 0 ? 1 + kilometers.length : 0);
  if (rowsNeeded > capacity) {
    throw new CapacityError(
      `"${schema.title}" has ${rowsNeeded} rows to write but the template only has room for ${capacity} in this period.`
    );
  }

  const firstCatCol = schema.categoryColumns[0]?.letter;
  const lastCatCol = schema.categoryColumns[schema.categoryColumns.length - 1]?.letter;

  // The bundled "template" is actually a filled sample report - clear every
  // data cell in the full range first so no leftover sample receipt (a
  // different date/description/amount from a past period) leaks through a
  // row this period doesn't happen to write to (e.g. the blank spacer row
  // before Kilometers, or any row past however many entries this period has).
  for (let rowNum = schema.dataRowStart; rowNum <= schema.dataRowEnd; rowNum++) {
    clearRow(rowNum);
  }

  function clearRow(rowNum: number) {
    next = clearCell(next, `A${rowNum}`);
    next = clearCell(next, `B${rowNum}`);
    for (const col of schema.categoryColumns) {
      next = clearCell(next, `${col.letter}${rowNum}`);
    }
    next = clearCell(next, `${schema.netBeforeGstColumn}${rowNum}`);
    next = clearCell(next, `${schema.gstColumn}${rowNum}`);
    next = clearCell(next, `${schema.totalColumn}${rowNum}`);
  }

  const writeRow = (rowNum: number, e: ExpenseEntry, categoryLetter: string, amount: number, gst: number | null) => {
    next = setCellNumber(next, `A${rowNum}`, dateToExcelSerial(fromIsoDate(e.date)));
    next = setCellInlineString(next, `B${rowNum}`, e.description);
    next = setCellNumber(next, `${categoryLetter}${rowNum}`, amount);

    const netFormula =
      firstCatCol === lastCatCol ? `${firstCatCol}${rowNum}` : `SUM(${firstCatCol}${rowNum}:${lastCatCol}${rowNum})`;
    next = setCellFormula(next, `${schema.netBeforeGstColumn}${rowNum}`, netFormula, amount);

    if (gst !== null) {
      next = setCellNumber(next, `${schema.gstColumn}${rowNum}`, gst);
    }
    const gstRef = gst !== null ? `${schema.gstColumn}${rowNum}` : "0";
    next = setCellFormula(
      next,
      `${schema.totalColumn}${rowNum}`,
      `${schema.netBeforeGstColumn}${rowNum}+${gstRef}`,
      amount + (gst ?? 0)
    );
  };

  receipts.forEach((entry, index) => {
    const rowNum = schema.dataRowStart + index;
    const category = schema.categoryColumns.find((c) => c.key === entry.categoryKey) ?? schema.categoryColumns[0];
    if (!category) throw new Error(`"${schema.title}" has no category columns to write receipts into.`);
    writeRow(rowNum, entry, category.letter, entry.netBeforeGst, entry.gst);
  });

  if (kilometers.length > 0) {
    const kmColumn = findMileageCategoryColumn(schema) ?? schema.categoryColumns[0];
    if (!kmColumn) throw new Error(`"${schema.title}" has no category column to write Kilometers claims into.`);
    const kmStartRow = schema.dataRowStart + receipts.length + 1; // +1 = mandatory blank spacer row
    kilometers.forEach((entry, index) => {
      const rowNum = kmStartRow + index;
      writeRow(rowNum, entry, kmColumn.letter, entry.amount, null);
    });
  }

  return next;
}

export function writeDrivingDetailsSheet(xml: string, entries: DrivingDetailEntry[]): string {
  let next = xml;
  const capacity = drivingSchema.dataRowEnd - drivingSchema.dataRowStart + 1;
  if (entries.length > capacity) {
    throw new CapacityError(`Driving Details has ${entries.length} entries but the template only has room for ${capacity}.`);
  }
  const c = drivingSchema.columns;
  // Same leftover-sample-data concern as writeCompanySheet - clear Date/
  // Trip/KM for the full range first (Total $ in column D is left alone,
  // its formula is what we want to keep either way).
  for (let rowNum = drivingSchema.dataRowStart; rowNum <= drivingSchema.dataRowEnd; rowNum++) {
    next = clearCell(next, `${c.date}${rowNum}`);
    next = clearCell(next, `${c.trip}${rowNum}`);
    next = clearCell(next, `${c.km}${rowNum}`);
  }
  entries.forEach((entry, index) => {
    const rowNum = drivingSchema.dataRowStart + index;
    next = setCellNumber(next, `${c.date}${rowNum}`, dateToExcelSerial(fromIsoDate(entry.date)));
    next = setCellInlineString(next, `${c.trip}${rowNum}`, entry.trip);
    next = setCellNumber(next, `${c.km}${rowNum}`, entry.km);
    // Total $ formula already exists in every row of the pristine template - left untouched.
  });
  return next;
}
