#!/usr/bin/env node
/**
 * Dev-time schema extraction.
 *
 * Reads the real .xlsx templates in templates/ and emits static JSON
 * describing each sheet's real headers, data-row range and semantic
 * column roles into src/assets/schema/. The app bundles that JSON and
 * never needs to parse OOXML headers on-device; if the templates ever
 * change, rerun this script (`npm run extract-schema`) and commit the
 * regenerated JSON.
 *
 * Uses the `xlsx` (SheetJS) package, which is only a devDependency -
 * it is fine for *reading* templates, but the app's own write path uses
 * a hand-rolled surgical OOXML patcher (src/services/excel) specifically
 * because SheetJS's writer does not reliably round-trip merges/styles.
 */
const fs = require("fs");
const path = require("path");
const XLSX = require("xlsx");

const ROOT = path.join(__dirname, "..");
const TEMPLATES_DIR = path.join(ROOT, "templates");
const OUT_DIR = path.join(ROOT, "src", "assets", "schema");

const TIMESHEET_FILE = "Volodymyr Payroll Timesheet.xlsx";
const EXPENSE_FILE = "Mileage Report - Volodymyr.xlsx";

function colLetter(index0) {
  let n = index0 + 1;
  let s = "";
  while (n > 0) {
    const rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = Math.floor((n - 1) / 26);
  }
  return s;
}

function cellText(ws, r, c) {
  const addr = XLSX.utils.encode_cell({ r, c });
  const cell = ws[addr];
  if (!cell || cell.v === undefined || cell.v === null) return "";
  return String(cell.v).trim();
}

function isMergedAt(merges, r, c) {
  return merges.find(
    (m) => r >= m.s.r && r <= m.e.r && c >= m.s.c && c <= m.e.c && !(m.s.r === r && m.s.c === c && m.e.r === r && m.e.c === c)
  );
}

/** Width (in columns) of the merge starting at r,c, or 1 if not merged. */
function mergeWidthAt(merges, r, c) {
  const m = merges.find((mm) => mm.s.r === r && mm.s.c === c);
  return m ? m.e.c - m.s.c + 1 : 1;
}

function extractExpenseReport() {
  const wb = XLSX.readFile(path.join(TEMPLATES_DIR, EXPENSE_FILE), { cellFormula: true });

  // Row/col indices are 0-based here (SheetJS convention); we store 1-based
  // spreadsheet row numbers and column letters in the emitted schema.
  const HEADER_ROW5 = 4; // "Net before" super-header
  const HEADER_ROW6 = 5; // main header row
  const HEADER_ROW7 = 6; // second header line for split headers
  const DATA_ROW_START = 8; // 1-based
  const DATA_ROW_END = 27; // 1-based
  const SUBTOTAL_ROW = 28; // 1-based
  const TOTAL_CLAIMED_ROW = 31; // 1-based

  const companies = wb.SheetNames.filter((sheetName) => sheetName !== "Driving Details").map((sheetName) => {
    const ws = wb.Sheets[sheetName];
    const merges = ws["!merges"] || [];
    const range = XLSX.utils.decode_range(ws["!ref"]);

    const titleText = cellText(ws, 0, 0); // row1
    const dateCol = colLetter(1); // B = Description always at index 1

    // Find semantic columns by structure, not by hardcoded letter:
    // "Net before"/GST is the first 2-wide merge on row6 whose row5 label
    // is "Net before"; GST is the next single (non-merged) column with
    // header "GST"; TOTAL is the following 2-wide merge headed "TOTAL".
    let netBeforeGstCol = null;
    let gstCol = null;
    let totalCol = null;
    for (let c = 2; c <= range.e.c; c++) {
      const row5 = cellText(ws, HEADER_ROW5, c);
      const row6 = cellText(ws, HEADER_ROW6, c);
      if (netBeforeGstCol === null && /net before/i.test(row5) && mergeWidthAt(merges, HEADER_ROW6, c) > 1) {
        netBeforeGstCol = colLetter(c);
        continue;
      }
      if (netBeforeGstCol !== null && gstCol === null && /^gst$/i.test(row6) && mergeWidthAt(merges, HEADER_ROW6, c) === 1) {
        gstCol = colLetter(c);
        continue;
      }
      if (gstCol !== null && totalCol === null && /^total$/i.test(row6)) {
        totalCol = colLetter(c);
        continue;
      }
    }
    if (!netBeforeGstCol || !gstCol || !totalCol) {
      throw new Error(`Could not locate Net-before-GST/GST/TOTAL columns on sheet "${sheetName}"`);
    }

    // Category columns: everything between Description (B) and Net-before-GST
    // that has real header text on row6 (optionally continued on row7).
    const categoryColumns = [];
    const netBeforeIdx = XLSX.utils.decode_col(netBeforeGstCol);
    for (let c = 2; c < netBeforeIdx; c++) {
      const row5 = cellText(ws, HEADER_ROW5, c);
      const row6 = cellText(ws, HEADER_ROW6, c);
      const row7 = cellText(ws, HEADER_ROW7, c);
      const label = [row5, row6, row7].filter(Boolean).join(" ").replace(/\s+/g, " ").trim();
      if (!label) continue; // decorative/unused column (e.g. the bare "N" column)
      categoryColumns.push({
        letter: colLetter(c),
        label,
        key: label
          .toLowerCase()
          .replace(/[^a-z0-9]+/g, "_")
          .replace(/^_+|_+$/g, ""),
      });
    }

    return {
      sheetName, // internal workbook tab name - may differ from title text (e.g. Bryco tab is literally "Sheet1")
      title: titleText,
      dateColumn: "A",
      descriptionColumn: dateCol,
      categoryColumns,
      netBeforeGstColumn: netBeforeGstCol,
      gstColumn: gstCol,
      totalColumn: totalCol,
      headerRow6: HEADER_ROW6 + 1,
      dataRowStart: DATA_ROW_START,
      dataRowEnd: DATA_ROW_END,
      subtotalRow: SUBTOTAL_ROW,
      totalClaimedRow: TOTAL_CLAIMED_ROW,
    };
  });

  return {
    sourceFile: EXPENSE_FILE,
    sheetOrder: wb.SheetNames, // preserve exact tab order/inclusion, incl. Driving Details' position
    companies,
  };
}

function extractDrivingDetails() {
  const wb = XLSX.readFile(path.join(TEMPLATES_DIR, EXPENSE_FILE));
  const ws = wb.Sheets["Driving Details"];
  if (!ws) throw new Error('Sheet "Driving Details" not found in Mileage Report template');

  return {
    sourceFile: EXPENSE_FILE,
    sheetName: "Driving Details",
    columns: { date: "A", trip: "B", km: "C", totalDollars: "D" },
    dataRowStart: 2,
    dataRowEnd: 18,
    totalRow: 19,
    kmPerDollarRate: 0.56,
  };
}

function extractTimesheet() {
  const wb = XLSX.readFile(path.join(TEMPLATES_DIR, TIMESHEET_FILE));
  const sheetName = wb.SheetNames[0];
  const ws = wb.Sheets[sheetName];

  return {
    sourceFile: TIMESHEET_FILE,
    sheetName,
    titleCell: "A1",
    employeeNameCell: "C2",
    payPeriodCell: "C5",
    employeePhoneCell: "C6",
    headerRow: 7,
    columns: {
      itemNumber: "A",
      date: "B",
      startTime: "C",
      lunchBreak: "D",
      coffeeBreak: "E",
      finishTime: "F",
      hours: "G",
      total: "H",
    },
    dataRowStart: 8,
    dataRowEnd: 38,
    totalHoursLabelCell: "G39",
    totalHoursValueCell: "H39",
  };
}

function main() {
  fs.mkdirSync(OUT_DIR, { recursive: true });

  const timesheet = extractTimesheet();
  const expenseReport = extractExpenseReport();
  const drivingDetails = extractDrivingDetails();

  fs.writeFileSync(path.join(OUT_DIR, "timesheet.json"), JSON.stringify(timesheet, null, 2) + "\n");
  fs.writeFileSync(path.join(OUT_DIR, "expenseReport.json"), JSON.stringify(expenseReport, null, 2) + "\n");
  fs.writeFileSync(path.join(OUT_DIR, "drivingDetails.json"), JSON.stringify(drivingDetails, null, 2) + "\n");

  console.log("Wrote schema:");
  console.log("  timesheet.json:", timesheet.sheetName);
  console.log(
    "  expenseReport.json companies:",
    expenseReport.companies.map((c) => `${c.sheetName} [${c.categoryColumns.map((x) => x.letter).join(",")}]`).join(" | ")
  );
  console.log("  drivingDetails.json:", drivingDetails.sheetName);
}

main();
