#!/usr/bin/env node
/**
 * Round-trip verification for the Timesheet writer
 * (src/services/excel/timesheetSheet.ts), against the real template.
 *
 * The real template is Volodymyr's actual filled sample: rows 11-15 and
 * 19-22 have real "8am"/"430pm"/8/8 entries for HIS period's weekdays.
 * Regenerating for a DIFFERENT period (different weekday/weekend layout,
 * possibly shorter) must not leave any of that behind on rows this period
 * doesn't happen to write real hours to.
 *
 * Run with: npm run verify-timesheet-writer
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import JSZip from "jszip";
import XLSX from "xlsx";
import { writeTimesheetSheet } from "../src/services/excel/timesheetSheet.ts";
import { getPeriodForDate, generateDefaultTimesheetRows } from "../src/services/payroll/periodEngine.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const TEMPLATES_DIR = path.join(ROOT, "templates");
const FILE = "Volodymyr Payroll Timesheet.xlsx";
const OUT_DIR = path.join(ROOT, "tmp-verify");

let failures = 0;
function check(label, cond, detail) {
  if (cond) {
    console.log(`  OK   ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail ? " - " + detail : ""}`);
  }
}

async function getSheetPath(zip, sheetName) {
  const workbookXml = await zip.file("xl/workbook.xml").async("text");
  const relsXml = await zip.file("xl/_rels/workbook.xml.rels").async("text");
  const attr = (tag, name) => new RegExp(`\\b${name}="([^"]*)"`).exec(tag)?.[1];
  const ridToTarget = new Map();
  for (const tag of relsXml.match(/<Relationship\b[^>]*\/?>/g) ?? []) {
    const id = attr(tag, "Id");
    const target = attr(tag, "Target");
    if (id && target) ridToTarget.set(id, target);
  }
  for (const tag of workbookXml.match(/<sheet\b[^>]*\/?>/g) ?? []) {
    if (attr(tag, "name") !== sheetName) continue;
    const target = ridToTarget.get(attr(tag, "r:id"));
    return target.startsWith("/") ? target.slice(1) : `xl/${target}`;
  }
  throw new Error(`sheet ${sheetName} not found`);
}

async function main() {
  const pristineWb = XLSX.readFile(path.join(TEMPLATES_DIR, FILE));
  check(
    "sanity: pristine row 11 really does have a real sample hours value",
    pristineWb.Sheets["Sheet1"]["G11"]?.v === 8
  );

  // A period far from the original sample's own dates, so its
  // weekend/weekday layout is guaranteed to differ from the sample's.
  const period = getPeriodForDate(new Date(2027, 2, 15)); // March 2027
  const rows = generateDefaultTimesheetRows(period);

  const zip = await JSZip.loadAsync(fs.readFileSync(path.join(TEMPLATES_DIR, FILE)));
  const sheetPath = await getSheetPath(zip, "Sheet1");
  let xml = await zip.file(sheetPath).async("text");
  xml = writeTimesheetSheet(xml, { fullName: "Test Employee", phone: "555-0100" }, period, rows);
  zip.file(sheetPath, xml);

  fs.mkdirSync(OUT_DIR, { recursive: true });
  const outPath = path.join(OUT_DIR, "timesheet-writer-regression.xlsx");
  fs.writeFileSync(outPath, await zip.generateAsync({ type: "nodebuffer" }));

  const wb = XLSX.readFile(outPath, { cellFormula: true });
  const ws = wb.Sheets["Sheet1"];

  check(`generated period ${period.startDate}..${period.endDate}`, true);
  check("row 11 has this period's own data now (not the sample's 8am/8h)", ws["G11"] === undefined || typeof ws["G11"].f === "string");

  // Any row beyond this period's own day count must be fully cleared,
  // even though the pristine sample had real hours there (rows 11-15/19-22).
  const rowsUsed = rows.length;
  for (let i = rowsUsed; i <= 15; i++) {
    const rowNum = 8 + i;
    check(`row ${rowNum} (past this period's ${rowsUsed} days) is cleared`, ws[`B${rowNum}`] === undefined, JSON.stringify(ws[`B${rowNum}`]));
  }

  console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
