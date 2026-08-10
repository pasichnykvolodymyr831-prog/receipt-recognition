#!/usr/bin/env node
/**
 * Verification for the offline receipt text parser, against synthetic OCR
 * text samples modeled on real receipt layouts (label/value on the same
 * line, label/value split across lines the way ML Kit often reads columns,
 * different date formats, French/English bilingual Canadian receipts).
 *
 * Run with: npm run verify-offline-receipt-parser
 */
import { parseReceiptText } from "../src/services/ocr/offlineReceiptParser.ts";

let failures = 0;
function check(label, cond, detail) {
  if (cond) {
    console.log(`  OK   ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail !== undefined ? " - " + JSON.stringify(detail) : ""}`);
  }
}

console.log("== Home Depot style receipt (label + value same line) ==");
{
  const text = [
    "THE HOME DEPOT",
    "123 Main St",
    "Calgary, AB",
    "",
    "PAINT SUPPLIES         42.50",
    "SCREWS 1/2IN             5.25",
    "SUBTOTAL                47.75",
    "GST                      2.39",
    "TOTAL                   50.14",
    "07/25/2026",
  ].join("\n");
  const result = parseReceiptText(text);
  check("vendor name", result.vendorNameRaw === "THE HOME DEPOT", result.vendorNameRaw);
  check("net before GST (subtotal)", result.netBeforeGst === 47.75, result.netBeforeGst);
  check("gst", result.gst === 2.39, result.gst);
  check("date (MM/DD/YYYY)", result.date === "2026-07-25", result.date);
}

console.log("\n== Split label/value across lines (common OCR column split) ==");
{
  const text = ["Metro Liquor Store", "Date: Aug 3, 2026", "Sub-Total", "18.00", "GST", "0.90", "Total", "18.90"].join(
    "\n"
  );
  const result = parseReceiptText(text);
  check("vendor name", result.vendorNameRaw === "Metro Liquor Store", result.vendorNameRaw);
  check("date (Month D, Y)", result.date === "2026-08-03", result.date);
  check("net before GST split across lines", result.netBeforeGst === 18.0, result.netBeforeGst);
  check("gst split across lines", result.gst === 0.9, result.gst);
}

console.log("\n== HST instead of GST (Ontario-style receipt) ==");
{
  const text = ["Tim Hortons #4471", "15 Aug 2026", "Subtotal    8.85", "HST    1.15", "Total    10.00"].join("\n");
  const result = parseReceiptText(text);
  check("date (D Month Y)", result.date === "2026-08-15", result.date);
  check("HST recognized as gst", result.gst === 1.15, result.gst);
  check("net before GST", result.netBeforeGst === 8.85, result.netBeforeGst);
}

console.log("\n== ISO date format ==");
{
  const text = ["Office Depot", "2026-07-09", "Subtotal 10.00", "GST 0.50"].join("\n");
  const result = parseReceiptText(text);
  check("ISO date", result.date === "2026-07-09", result.date);
}

console.log("\n== Ambiguous numeric date, day unambiguous (25 can't be a month) ==");
{
  const text = ["Some Store", "25/12/2026", "Subtotal 5.00"].join("\n");
  const result = parseReceiptText(text);
  check("25/12/2026 -> Dec 25 (day-first, since 25 can't be a month)", result.date === "2026-12-25", result.date);
}

console.log("\n== Missing fields degrade gracefully (no false positives) ==");
{
  const text = ["A Store With No Totals", "Thanks for shopping!"].join("\n");
  const result = parseReceiptText(text);
  check("date is null", result.date === null, result.date);
  check("gst is null", result.gst === null, result.gst);
  check("netBeforeGst is null", result.netBeforeGst === null, result.netBeforeGst);
  check("vendor name still found", result.vendorNameRaw === "A Store With No Totals", result.vendorNameRaw);
}

console.log("\n== 'Taxi'/'Total' near-miss words don't false-match tax/subtotal patterns ==");
{
  const text = ["Taxi Receipt Co", "Fare Total 25.00"].join("\n");
  const result = parseReceiptText(text);
  check("'Taxi' does not match \\btax\\b", result.gst === null, result.gst);
  check("'Total' alone does not match \\bsub-?total\\b", result.netBeforeGst === null, result.netBeforeGst);
}

console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED"}`);
process.exit(failures === 0 ? 0 : 1);
