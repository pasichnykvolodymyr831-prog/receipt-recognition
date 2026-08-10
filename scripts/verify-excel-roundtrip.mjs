#!/usr/bin/env node
/**
 * Round-trip verification for the surgical OOXML cell patcher.
 *
 * Loads each real template into JSZip (exactly like the on-device engine
 * will), applies a representative set of writes using the SAME pure
 * ooxml.ts functions the app uses, saves it, then re-opens the result
 * with the `xlsx` (SheetJS) reader to assert:
 *   - cells we wrote have the expected value/formula
 *   - formulas we wrote are real formulas (not cached numbers)
 *   - merges list is byte-identical to the original (nothing shifted)
 *   - a sampling of cells we did NOT touch are unchanged
 *
 * Run with: node --experimental-strip-types scripts/verify-excel-roundtrip.js
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import JSZip from "jszip";
import XLSX from "xlsx";
import {
  setCellNumber,
  setCellInlineString,
  setCellFormula,
  clearCell,
  getCellStyleId,
} from "../src/services/excel/ooxml.ts";
import { dateToExcelSerial, timeOfDayToExcelFraction, durationMinutesToExcelFraction } from "../src/services/excel/excelDates.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const TEMPLATES_DIR = path.join(ROOT, "templates");
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

async function loadZip(fileName) {
  const buf = fs.readFileSync(path.join(TEMPLATES_DIR, fileName));
  return JSZip.loadAsync(buf);
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

async function verifyTimesheet() {
  console.log("\n== Timesheet ==");
  const fileName = "Volodymyr Payroll Timesheet.xlsx";
  const zip = await loadZip(fileName);
  const sheetPath = await getSheetPath(zip, "Sheet1");
  let xml = await zip.file(sheetPath).async("text");

  const originalStyleC11 = getCellStyleId(xml, "C11");

  // Write a full day row (row 16, currently blank) with real time-of-day
  // values + working formulas, mirroring what the Timesheet screen will do.
  const start = timeOfDayToExcelFraction(8, 0);
  const lunchStart = timeOfDayToExcelFraction(12, 0);
  const lunchDuration = durationMinutesToExcelFraction(30);
  const finish = timeOfDayToExcelFraction(16, 30);
  xml = setCellNumber(xml, "C16", start);
  xml = setCellNumber(xml, "D16", lunchDuration);
  xml = setCellNumber(xml, "F16", finish);
  const hoursValue = (finish - start - lunchDuration - 0) * 24;
  xml = setCellFormula(xml, "G16", "(F16-C16-D16-E16)*24", hoursValue);
  xml = setCellFormula(xml, "H16", "G16", hoursValue);
  xml = setCellFormula(xml, "H39", "SUM(G8:G38)", hoursValue);

  zip.file(sheetPath, xml);
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const outPath = path.join(OUT_DIR, "timesheet-out.xlsx");
  const outBuf = await zip.generateAsync({ type: "nodebuffer" });
  fs.writeFileSync(outPath, outBuf);

  const originalWb = XLSX.readFile(path.join(TEMPLATES_DIR, fileName), { cellFormula: true });
  const wb = XLSX.readFile(outPath, { cellFormula: true });
  const ws = wb.Sheets["Sheet1"];
  const originalWs = originalWb.Sheets["Sheet1"];

  check("C16 start time value", Math.abs(ws["C16"].v - start) < 1e-9);
  check("G16 has formula (not cached number)", !!ws["G16"].f, ws["G16"].f);
  check("G16 formula text correct", ws["G16"].f === "(F16-C16-D16-E16)*24", ws["G16"].f);
  check("H16 formula correct", ws["H16"].f === "G16", ws["H16"].f);
  check("H39 (Total Hrs) is now a real formula", ws["H39"].f === "SUM(G8:G38)", ws["H39"].f);
  check(
    "merges unchanged",
    JSON.stringify(ws["!merges"]) === JSON.stringify(originalWs["!merges"]),
    JSON.stringify(ws["!merges"])
  );
  check("untouched cell C2 (employee name) unchanged", ws["C2"].v === originalWs["C2"].v);
  check("untouched cell A1 (title) unchanged", ws["A1"].v === originalWs["A1"].v);
  check("style id on C11 unaffected by our edits elsewhere", getCellStyleId(xml, "C11") === originalStyleC11);
}

async function verifyExpenseReport() {
  console.log("\n== Expense Report (Truman Homes) ==");
  const fileName = "Mileage Report - Volodymyr.xlsx";
  const zip = await loadZip(fileName);
  const sheetPath = await getSheetPath(zip, "Truman Homes");
  let xml = await zip.file(sheetPath).async("text");

  const row = 16; // currently-blank data row
  const dateSerial = dateToExcelSerial(new Date(2026, 6, 30));
  xml = setCellNumber(xml, `A${row}`, dateSerial);
  xml = setCellInlineString(xml, `B${row}`, "Test receipt from round-trip check");
  xml = setCellNumber(xml, `D${row}`, 42.5); // Materials category
  xml = setCellFormula(xml, `I${row}`, `H${row}+G${row}+F${row}+E${row}+D${row}+C${row}`, 42.5);
  xml = setCellNumber(xml, `K${row}`, 2.13); // GST as read from the receipt
  xml = setCellFormula(xml, `L${row}`, `K${row}+I${row}`, 44.63);

  // Kilometers row, two rows below (one blank spacer row preserved)
  const kmRow = row + 2;
  xml = setCellInlineString(xml, `B${kmRow}`, "Kilometers (25)");
  xml = setCellNumber(xml, `E${kmRow}`, 14.0);
  xml = setCellFormula(xml, `I${kmRow}`, `H${kmRow}+G${kmRow}+F${kmRow}+E${kmRow}+D${kmRow}+C${kmRow}`, 14.0);

  zip.file(sheetPath, xml);
  fs.mkdirSync(OUT_DIR, { recursive: true });
  const outPath = path.join(OUT_DIR, "expense-out.xlsx");
  fs.writeFileSync(outPath, await zip.generateAsync({ type: "nodebuffer" }));

  const originalWb = XLSX.readFile(path.join(TEMPLATES_DIR, fileName), { cellFormula: true });
  const wb = XLSX.readFile(outPath, { cellFormula: true });
  const ws = wb.Sheets["Truman Homes"];
  const originalWs = originalWb.Sheets["Truman Homes"];

  check("A16 date value", ws["A16"].v === dateSerial);
  check("B16 description text", ws["B16"].v === "Test receipt from round-trip check");
  check("D16 category amount", ws["D16"].v === 42.5);
  check("I16 Net-before-GST is a formula", ws["I16"].f === "H16+G16+F16+E16+D16+C16", ws["I16"].f);
  check("L16 Total is a formula", ws["L16"].f === "K16+I16", ws["L16"].f);
  check("B18 Kilometers row text", ws["B18"].v === "Kilometers (25)");
  check("B17 spacer row still blank", ws["B17"] === undefined);
  check(
    "merges unchanged",
    JSON.stringify(ws["!merges"]) === JSON.stringify(originalWs["!merges"])
  );
  // Existing formula on an untouched row (row 9) must survive byte-for-byte
  check("untouched row 9 formula intact", ws["I9"].f === originalWs["I9"].f, `${ws["I9"] && ws["I9"].f} vs ${originalWs["I9"].f}`);
  check("other sheet (Lionsworthe) A1 title untouched", wb.Sheets["Lionsworthe"]["A1"].v === originalWb.Sheets["Lionsworthe"]["A1"].v);
  check("sheet tab order preserved", JSON.stringify(wb.SheetNames) === JSON.stringify(originalWb.SheetNames));
}

async function verifyDrivingDetails() {
  console.log("\n== Driving Details ==");
  const fileName = "Mileage Report - Volodymyr.xlsx";
  const zip = await loadZip(fileName);
  const sheetPath = await getSheetPath(zip, "Driving Details");
  let xml = await zip.file(sheetPath).async("text");

  // Simulate period reset: clear existing entries but keep formula rows.
  for (let r = 2; r <= 18; r++) {
    xml = clearCell(xml, `A${r}`);
    xml = clearCell(xml, `B${r}`);
    xml = clearCell(xml, `C${r}`);
    // D column (Total $ formula) intentionally left untouched.
  }
  // Then write one new entry.
  xml = setCellNumber(xml, "A2", dateToExcelSerial(new Date(2026, 7, 1)));
  xml = setCellInlineString(xml, "B2", "Office - Site A - Office");
  xml = setCellNumber(xml, "C2", 12);

  zip.file(sheetPath, xml);
  const outPath = path.join(OUT_DIR, "driving-out.xlsx");
  fs.writeFileSync(outPath, await zip.generateAsync({ type: "nodebuffer" }));

  const wb = XLSX.readFile(outPath, { cellFormula: true });
  const ws = wb.Sheets["Driving Details"];

  check("A2 new date", ws["A2"].v === dateToExcelSerial(new Date(2026, 7, 1)));
  check("C2 new km", ws["C2"].v === 12);
  check("D2 formula survived the reset untouched", ws["D2"].f === "SUM(C2*0.56)", ws["D2"].f);
  check("A7 cleared (old data gone)", ws["A7"] === undefined);
  check("D7 formula still present after clearing A7/B7/C7", ws["D7"].f === "SUM(C7*0.56)", ws["D7"].f);
  check("Total row formula (C19) untouched", ws["C19"].f === "SUM(C2:C18)", ws["C19"].f);
  check("Total row formula (D19) untouched", ws["D19"].f === "SUM(D2:D18)", ws["D19"].f);
}

async function main() {
  await verifyTimesheet();
  await verifyExpenseReport();
  await verifyDrivingDetails();

  console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED"}`);
  console.log(`Inspect the generated files manually in: ${OUT_DIR}`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
