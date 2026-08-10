/**
 * Metro asset module ids for the real company Excel templates. These
 * files live in templates/ at the repo root (gitignored - they contain
 * real personal/employer data, see .gitignore) but are still available
 * locally and to EAS builds (see .easignore), and get bundled as binary
 * assets by Metro (see metro.config.js: "xlsx" added to assetExts).
 *
 * Use src/services/excel/templateAccess.ts to turn these into an
 * XlsxDocument at runtime.
 */
import TIMESHEET_TEMPLATE_MODULE from "../../templates/Volodymyr Payroll Timesheet.xlsx";
import EXPENSE_REPORT_TEMPLATE_MODULE from "../../templates/Mileage Report - Volodymyr.xlsx";

export { TIMESHEET_TEMPLATE_MODULE, EXPENSE_REPORT_TEMPLATE_MODULE };
