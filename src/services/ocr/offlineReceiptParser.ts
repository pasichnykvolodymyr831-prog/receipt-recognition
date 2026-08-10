/**
 * Pure heuristic parser for on-device receipt OCR text (no ML Kit/native
 * imports here - testable directly from plain Node, see
 * scripts/verify-offline-receipt-parser.mjs).
 *
 * Deliberately narrow scope, per spec: recognizes only date, GST, the
 * amount before GST, and the vendor name. Category is always a manual,
 * required user choice (a keyword-matched guess is not reliable enough to
 * default to), and Total is never computed here - it stays a real Excel
 * formula (GST + Net before GST) written by expenseReportSheets.ts.
 */

export interface OfflineReceiptFields {
  date: string | null; // ISO yyyy-mm-dd
  netBeforeGst: number | null;
  gst: number | null;
  vendorNameRaw: string | null;
}

const MONTH_INDEX: Record<string, number> = {
  jan: 0, january: 0,
  feb: 1, february: 1,
  mar: 2, march: 2,
  apr: 3, april: 3,
  may: 4,
  jun: 5, june: 5,
  jul: 6, july: 6,
  aug: 7, august: 7,
  sep: 8, sept: 8, september: 8,
  oct: 9, october: 9,
  nov: 10, november: 10,
  dec: 11, december: 11,
};

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

/** Two-digit years on receipts are almost always this century; pivot arbitrarily at 70. */
function normalizeYear(year: number): number {
  if (year >= 100) return year;
  return year < 70 ? 2000 + year : 1900 + year;
}

function isValidDate(year: number, month1based: number, day: number): boolean {
  return month1based >= 1 && month1based <= 12 && day >= 1 && day <= 31 && year >= 2000 && year <= 2100;
}

const MONEY_PATTERN = /\$?\s?(\d{1,6}[.,]\d{2})\b/;

function parseMoney(raw: string): number | null {
  const normalized = raw.replace(/[^0-9.,]/g, "").replace(",", ".");
  const value = Number.parseFloat(normalized);
  return Number.isFinite(value) ? Math.round(value * 100) / 100 : null;
}

/**
 * Numeric D/M/Y (or M/D/Y - ambiguous when both parts are <= 12; North
 * American receipts skew month-first, so that's the tiebreak), ISO Y-M-D,
 * and "Month D, Y" / "D Month Y" forms.
 */
function extractDate(rawText: string): string | null {
  const iso = /\b(\d{4})[\/\-.](\d{1,2})[\/\-.](\d{1,2})\b/.exec(rawText);
  if (iso) {
    const year = Number(iso[1]);
    const month = Number(iso[2]);
    const day = Number(iso[3]);
    if (isValidDate(year, month, day)) return `${year}-${pad2(month)}-${pad2(day)}`;
  }

  const numeric = /\b(\d{1,2})[\/\-.](\d{1,2})[\/\-.](\d{2,4})\b/.exec(rawText);
  if (numeric) {
    const year = normalizeYear(Number(numeric[3]));
    let first = Number(numeric[1]);
    let second = Number(numeric[2]);
    // Unambiguous cases: whichever part is > 12 must be the day.
    if (first > 12 && second <= 12) {
      [first, second] = [second, first]; // -> month, day
    }
    const month = first;
    const day = second;
    if (isValidDate(year, month, day)) return `${year}-${pad2(month)}-${pad2(day)}`;
  }

  const monthFirst = /\b([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{2,4})\b/.exec(rawText);
  if (monthFirst) {
    const monthIndex = MONTH_INDEX[monthFirst[1].toLowerCase()];
    if (monthIndex !== undefined) {
      const year = normalizeYear(Number(monthFirst[3]));
      const day = Number(monthFirst[2]);
      if (isValidDate(year, monthIndex + 1, day)) return `${year}-${pad2(monthIndex + 1)}-${pad2(day)}`;
    }
  }

  const dayFirst = /\b(\d{1,2})\s+([A-Za-z]{3,9})\.?,?\s+(\d{2,4})\b/.exec(rawText);
  if (dayFirst) {
    const monthIndex = MONTH_INDEX[dayFirst[2].toLowerCase()];
    if (monthIndex !== undefined) {
      const year = normalizeYear(Number(dayFirst[3]));
      const day = Number(dayFirst[1]);
      if (isValidDate(year, monthIndex + 1, day)) return `${year}-${pad2(monthIndex + 1)}-${pad2(day)}`;
    }
  }

  return null;
}

/** Finds a money amount on a labeled line, or the following line (OCR often splits label/value across lines). */
function findLabeledAmount(lines: string[], labelPattern: RegExp): number | null {
  for (let i = 0; i < lines.length; i++) {
    if (!labelPattern.test(lines[i])) continue;
    const sameLine = MONEY_PATTERN.exec(lines[i]);
    if (sameLine) return parseMoney(sameLine[1]);
    const nextLine = lines[i + 1] ? MONEY_PATTERN.exec(lines[i + 1]) : null;
    if (nextLine) return parseMoney(nextLine[1]);
  }
  return null;
}

function extractGst(lines: string[]): number | null {
  return (
    findLabeledAmount(lines, /\bg\.?\s?s\.?\s?t\.?\b/i) ??
    findLabeledAmount(lines, /\bh\.?\s?s\.?\s?t\.?\b/i) ??
    findLabeledAmount(lines, /\btax\b/i)
  );
}

function extractNetBeforeGst(lines: string[]): number | null {
  return findLabeledAmount(lines, /\bsub\s?-?\s?total\b/i) ?? findLabeledAmount(lines, /\bnet\b/i);
}

/** The vendor name is almost always one of the first few printed lines. */
function extractVendorName(lines: string[]): string | null {
  for (const line of lines.slice(0, 5)) {
    const letterCount = (line.match(/[a-zA-Zа-яА-ЯёЁ]/g) ?? []).length;
    if (letterCount >= 3) return line;
  }
  return null;
}

export function parseReceiptText(rawText: string): OfflineReceiptFields {
  const lines = rawText
    .split(/\r?\n/)
    .map((line) => line.trim())
    .filter((line) => line.length > 0);

  return {
    date: extractDate(rawText),
    gst: extractGst(lines),
    netBeforeGst: extractNetBeforeGst(lines),
    vendorNameRaw: extractVendorName(lines),
  };
}
