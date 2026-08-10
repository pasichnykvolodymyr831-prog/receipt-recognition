/**
 * The six company tabs in the Expense Report workbook. This list (which
 * companies exist, their id/display name) is static business config - it
 * won't change without the company handing out a new template. What DOES
 * come from the real file at build time is each company's actual column
 * layout (see src/assets/schema/expenseReport.json, produced by
 * scripts/extract-schema.js) - never hardcoded here.
 *
 * `sheetName` is the internal OOXML tab name, which is what the Excel
 * engine needs to locate the sheet. Note Bryco's tab is literally named
 * "Sheet1" in the source workbook even though its printed title says
 * "Bryco Dirtworks Inc" - preserved as-is per the "stay structurally
 * identical to the template" requirement.
 */
export interface CompanyConfig {
  id: string;
  sheetName: string;
  displayName: string;
}

export const COMPANIES: readonly CompanyConfig[] = [
  { id: "truman-dev", sheetName: "Truman Dev", displayName: "Truman Development Corp" },
  { id: "truman-homes", sheetName: "Truman Homes", displayName: "Truman Homes 1995 Inc" },
  { id: "lionsworthe", sheetName: "Lionsworthe", displayName: "Lionsworthe Homes Inc" },
  { id: "taphouse", sheetName: "Taphouse", displayName: "North Tap House Chestermere" },
  { id: "metro", sheetName: "Metro", displayName: "Metro Liquor Store" },
  { id: "bryco", sheetName: "Sheet1", displayName: "Bryco Dirtworks Inc" },
] as const;

export type CompanyId = (typeof COMPANIES)[number]["id"];

export const DEFAULT_COMPANY_ID: CompanyId = "truman-homes";

export function getCompanyConfig(id: CompanyId): CompanyConfig {
  const company = COMPANIES.find((c) => c.id === id);
  if (!company) throw new Error(`Unknown company id "${id}"`);
  return company;
}
