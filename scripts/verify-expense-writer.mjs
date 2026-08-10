#!/usr/bin/env node
/**
 * Round-trip verification for the Expense Report / Driving Details writer
 * (src/services/excel/expenseReportWriter.ts), against the real template.
 *
 * Exercises: writing receipts into different companies with genuinely
 * different column layouts, the Kilometers spacer-row rule, a company with
 * no Auto/Travel column at all (falls back to first category), leaving
 * companies with no entries completely untouched, and Driving Details rows.
 *
 * Run with: npm run verify-expense-writer
 */
import fs from "node:fs";
import path from "node:path";
import { fileURLToPath } from "node:url";
import JSZip from "jszip";
import XLSX from "xlsx";
import expenseSchema from "../src/assets/schema/expenseReport.json" with { type: "json" };
import { writeCompanySheet, writeDrivingDetailsSheet, findMileageCategoryColumn } from "../src/services/excel/expenseReportSheets.ts";

const __dirname = path.dirname(fileURLToPath(import.meta.url));
const ROOT = path.join(__dirname, "..");
const TEMPLATES_DIR = path.join(ROOT, "templates");
const FILE = "Mileage Report - Volodymyr.xlsx";
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

function schemaFor(sheetName) {
  return expenseSchema.companies.find((c) => c.sheetName === sheetName);
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

const period = { startDate: "2026-07-24", endDate: "2026-08-08" };
const employee = { fullName: "Test Employee", phone: "+1 555 0100" };

async function main() {
  const zip = await JSZip.loadAsync(fs.readFileSync(path.join(TEMPLATES_DIR, FILE)));

  console.log("== Truman Homes: 2 receipts + 1 Kilometers claim ==");
  {
    const schema = schemaFor("Truman Homes");
    const sheetPath = await getSheetPath(zip, "Truman Homes");
    let xml = await zip.file(sheetPath).async("text");
    const entries = [
      {
        kind: "receipt",
        date: "2026-07-25",
        description: "Home Depot - paint",
        categoryKey: "materials",
        netBeforeGst: 42.5,
        gst: 2.13,
      },
      {
        kind: "receipt",
        date: "2026-07-26",
        description: "Office supplies",
        categoryKey: "office",
        netBeforeGst: 10,
        gst: 0.5,
      },
      { kind: "kilometers", date: "2026-07-27", description: "Kilometers (25)", km: 25, ratePerKm: 0.56, amount: 14 },
    ];
    xml = writeCompanySheet(xml, schema, employee, period, entries);
    zip.file(sheetPath, xml);

    const outPath = path.join(OUT_DIR, "expense-truman-homes.xlsx");
    fs.mkdirSync(OUT_DIR, { recursive: true });
    fs.writeFileSync(outPath, await zip.generateAsync({ type: "nodebuffer" }));
    const wb = XLSX.readFile(outPath, { cellFormula: true });
    const ws = wb.Sheets["Truman Homes"];

    check("B3 employee name written", ws["B3"].v === "Test Employee");
    check("receipt row 8: category (Materials/D) amount", ws["D8"].v === 42.5);
    check("receipt row 8: Net-before-GST formula", ws["I8"].f === "SUM(C8:H8)", ws["I8"] && ws["I8"].f);
    check("receipt row 8: Total formula", ws["L8"].f === "I8+K8", ws["L8"] && ws["L8"].f);
    check("receipt row 9: category (Office/C) amount", ws["C9"].v === 10);
    check("row 10 is the mandatory blank spacer", ws["A10"] === undefined && ws["B10"] === undefined);
    check("Kilometers row 11: description", ws["B11"].v === "Kilometers (25)");
    check("Kilometers row 11: amount in Travel column (E)", ws["E11"].v === 14);
    check("Kilometers row 11: GST left blank (KM claims aren't taxed)", ws["K11"] === undefined);
    check("untouched company (Lionsworthe) A1 title unchanged", wb.Sheets["Lionsworthe"]["A1"].v.includes("Lionsworthe"));
  }

  console.log("\n== Regression: no leftover sample data from the original filled report ==");
  {
    // The real template is Volodymyr's actual filled sample: row 9 has a
    // real "Home Depot" receipt, row 13 has a real "Kilometers (142)" row.
    // Writing just ONE receipt here must not leave any of that behind.
    const freshZip = await JSZip.loadAsync(fs.readFileSync(path.join(TEMPLATES_DIR, FILE)));
    const schema = schemaFor("Truman Homes");
    const sheetPath = await getSheetPath(freshZip, "Truman Homes");
    let xml = await freshZip.file(sheetPath).async("text");
    const pristineWb = XLSX.readFile(path.join(TEMPLATES_DIR, FILE));
    check(
      "sanity: pristine row 9 really does have real sample data",
      String(pristineWb.Sheets["Truman Homes"]["B9"]?.v ?? "").includes("Home Depot")
    );
    xml = writeCompanySheet(xml, schema, employee, period, [
      { kind: "receipt", date: "2026-07-25", description: "Single receipt", categoryKey: "office", netBeforeGst: 5, gst: 0.25 },
    ]);
    const outPath = path.join(OUT_DIR, "expense-leak-regression.xlsx");
    freshZip.file(sheetPath, xml);
    fs.writeFileSync(outPath, await freshZip.generateAsync({ type: "nodebuffer" }));
    const wb = XLSX.readFile(outPath, { cellFormula: true });
    const ws = wb.Sheets["Truman Homes"];
    check("row 9 (had a real Home Depot receipt) is cleared", ws["B9"] === undefined, JSON.stringify(ws["B9"]));
    check("row 10 (had a real receipt) is cleared", ws["B10"] === undefined, JSON.stringify(ws["B10"]));
    check("row 13 (had the real 'Kilometers (142)' row) is cleared", ws["B13"] === undefined, JSON.stringify(ws["B13"]));
    check("row 13 GST (had 5.29 in the sample) is cleared", ws["K13"] === undefined, JSON.stringify(ws["K13"]));
  }

  console.log("\n== Taphouse: no Auto/Travel column at all ==");
  {
    const schema = schemaFor("Taphouse");
    check("findMileageCategoryColumn returns null for Taphouse", findMileageCategoryColumn(schema) === null);
  }

  console.log("\n== Bryco (internal sheet name is literally 'Sheet1') ==");
  {
    const schema = schemaFor("Sheet1");
    check("schema resolved by internal sheet name, title mentions Bryco", schema.title.includes("Bryco"));
    const mileageCol = findMileageCategoryColumn(schema);
    check("Bryco's mileage column is Auto (C)", mileageCol && mileageCol.letter === "C", JSON.stringify(mileageCol));
  }

  console.log("\n== Driving Details ==");
  {
    const sheetPath = await getSheetPath(zip, "Driving Details");
    let xml = await zip.file(sheetPath).async("text");
    const entries = [
      { date: "2026-07-25", trip: "Storage - Site A - Storage", km: 15 },
      { date: "2026-07-26", trip: "Site A - Site B", km: 8 },
    ];
    xml = writeDrivingDetailsSheet(xml, entries);
    zip.file(sheetPath, xml);
    const outPath = path.join(OUT_DIR, "driving-details-writer.xlsx");
    fs.writeFileSync(outPath, await zip.generateAsync({ type: "nodebuffer" }));
    const wb = XLSX.readFile(outPath, { cellFormula: true });
    const ws = wb.Sheets["Driving Details"];
    check("row 2 trip text", ws["B2"].v === "Storage - Site A - Storage");
    check("row 2 km value", ws["C2"].v === 15);
    check("row 2 Total $ formula untouched", ws["D2"].f === "SUM(C2*0.56)", ws["D2"] && ws["D2"].f);
    check("Total row formula (C19) untouched", ws["C19"].f === "SUM(C2:C18)", ws["C19"] && ws["C19"].f);
  }

  console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED"}`);
  process.exit(failures === 0 ? 0 : 1);
}

main();
