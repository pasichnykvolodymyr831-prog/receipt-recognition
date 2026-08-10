import drivingSchema from "../../assets/schema/drivingDetails.json";
import { EXPENSE_REPORT_TEMPLATE_MODULE } from "../../assets/templates";
import { getCompanyConfig, type CompanyId } from "../../config/companies";
import type { DrivingDetailEntry, Employee, ExpenseEntry, PayPeriod } from "../../types/models";
import { findCompanySchema, writeCompanySheet, writeDrivingDetailsSheet } from "./expenseReportSheets";
import { openTemplateDocument, workingCopyUri } from "./templateAccess";

export interface WriteExpenseReportParams {
  employee: Employee;
  period: PayPeriod;
  expensesByCompany: Partial<Record<CompanyId, ExpenseEntry[]>>;
  drivingDetails: DrivingDetailEntry[];
}

/**
 * Regenerates this period's combined Expense Report / Mileage Report working
 * copy from the pristine template. Writes every company sheet that has
 * entries (companies with none are left completely untouched - still a
 * blank official form, per spec) and the Driving Details sheet if it has
 * entries. Both Phase 4 (receipts/Kilometers) and Phase 5 (Driving Details)
 * call this same function so the single combined workbook always reflects
 * all of a period's data at once, rather than each phase clobbering the
 * other's edits by regenerating from the pristine template independently.
 */
export async function writeExpenseReportWorkingCopy({
  employee,
  period,
  expensesByCompany,
  drivingDetails,
}: WriteExpenseReportParams): Promise<string> {
  const doc = await openTemplateDocument(EXPENSE_REPORT_TEMPLATE_MODULE);

  for (const companyId of Object.keys(expensesByCompany) as CompanyId[]) {
    const entries = expensesByCompany[companyId];
    if (!entries || entries.length === 0) continue;
    const company = getCompanyConfig(companyId);
    const schema = findCompanySchema(company.sheetName);
    const xml = await doc.getSheetXml(schema.sheetName);
    doc.setSheetXml(schema.sheetName, writeCompanySheet(xml, schema, employee, period, entries));
  }

  if (drivingDetails.length > 0) {
    const xml = await doc.getSheetXml(drivingSchema.sheetName);
    doc.setSheetXml(drivingSchema.sheetName, writeDrivingDetailsSheet(xml, drivingDetails));
  }

  const destUri = workingCopyUri(period.startDate, "ExpenseReport");
  await doc.saveToUri(destUri);
  return destUri;
}
