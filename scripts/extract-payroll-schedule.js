#!/usr/bin/env node
/**
 * Dev-time extraction of the payroll calendar from Payroll_Dates (2).xlsx,
 * Sheet2 (columns: PAY PERIOD / DUE BY / STAT HOLIDAY - DO NOT ENTER HOURS).
 *
 * The period boundaries themselves follow a fixed, deterministic semi-
 * monthly rule (9th-23rd, 24th-8th of next month - verified against every
 * row in the real file), so this script does NOT try to free-text-parse
 * the "PAY PERIOD" column. It instead regenerates periods algorithmically
 * in the same order the sheet lists them, and zips each computed period
 * with that row's real DUE BY / STAT HOLIDAY text - which frequently
 * contains genuine business exceptions (e.g. a due date 2 days before the
 * period even ends) that must come from the file, not be re-derived.
 *
 * Emits src/assets/schema/payrollSchedule.json.
 */
const fs = require("fs");
const path = require("path");
const XLSX = require("xlsx");

const ROOT = path.join(__dirname, "..");
const FILE = path.join(ROOT, "templates", "Payroll Dates (2).xlsx");
const OUT_FILE = path.join(ROOT, "src", "assets", "schema", "payrollSchedule.json");

const MONTHS = {
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

function monthIndex(name) {
  const key = name.trim().toLowerCase().replace(/\.$/, "");
  const idx = MONTHS[key];
  if (idx === undefined) throw new Error(`Unrecognized month name: "${name}"`);
  return idx;
}

function pad2(n) {
  return String(n).padStart(2, "0");
}

function isoDate(year, monthIndex0, day) {
  return `${year}-${pad2(monthIndex0 + 1)}-${pad2(day)}`;
}

function isoDateTime(year, monthIndex0, day, hour24, minute) {
  return `${isoDate(year, monthIndex0, day)}T${pad2(hour24)}:${pad2(minute)}:00`;
}

function to24Hour(hour12, ampm) {
  let h = hour12 % 12;
  if (/pm/i.test(ampm)) h += 12;
  return h;
}

/**
 * The company's fixed semi-monthly cycle: 9th-23rd, then 24th-end-of-cycle
 * (8th of the next month). Given the *start* date of one period, returns
 * the start date of the next.
 */
function nextPeriodStart(year, monthIndex0, day) {
  if (day === 9) {
    return { year, monthIndex0, day: 24 };
  }
  // day === 24: next period starts on the 9th of the following month.
  const nextMonth = monthIndex0 === 11 ? 0 : monthIndex0 + 1;
  const nextYear = monthIndex0 === 11 ? year + 1 : year;
  return { year: nextYear, monthIndex0: nextMonth, day: 9 };
}

function periodEnd(start) {
  if (start.day === 9) {
    return { year: start.year, monthIndex0: start.monthIndex0, day: 23 };
  }
  const nextMonth = start.monthIndex0 === 11 ? 0 : start.monthIndex0 + 1;
  const nextYear = start.monthIndex0 === 11 ? start.year + 1 : start.year;
  return { year: nextYear, monthIndex0: nextMonth, day: 8 };
}

/** Parses "Aug 21, 2026 - 4:30 PM" (year optional) into a due-datetime, given a fallback year. */
function parseDueDatePart(text, fallbackYear) {
  const m = /([A-Za-z]+)\.?\s+(\d{1,2})(?:st|nd|rd|th)?(?:,?\s*(\d{4}))?\s*[–—-]\s*(\d{1,2}):(\d{2})\s*(AM|PM)/i.exec(
    text
  );
  if (!m) return null;
  const [, monthName, dayStr, yearStr, hourStr, minStr, ampm] = m;
  const year = yearStr ? Number(yearStr) : fallbackYear;
  const mi = monthIndex(monthName);
  const day = Number(dayStr);
  const hour24 = to24Hour(Number(hourStr), ampm);
  return isoDateTime(year, mi, day, hour24, Number(minStr));
}

function parseDueBy(cellText, fallbackYear) {
  if (!cellText) return { primary: null, weekendAlternate: null };
  const weekendMatch = /\(([^)]*if\s+working\s+weekend[^)]*)\)/i.exec(cellText);
  const primaryText = weekendMatch ? cellText.slice(0, weekendMatch.index) : cellText;
  const primary = parseDueDatePart(primaryText, fallbackYear);
  const weekendAlternate = weekendMatch ? parseDueDatePart(weekendMatch[1], fallbackYear) : null;
  return { primary, weekendAlternate };
}

/** "Christmas Day – Dec 25, New Years Day - Jan 1" -> two {label, date} entries. */
function parseStatHolidays(cellText, period) {
  if (!cellText) return [];
  const trimmed = cellText.trim();
  if (!trimmed || /^n\/?a$/i.test(trimmed)) return [];

  const results = [];
  for (const segment of trimmed.split(",")) {
    const m = /^(.*?)\s*[–—-]\s*([A-Za-z]+)\.?\s+(\d{1,2})\s*$/.exec(segment.trim());
    if (!m) continue;
    const [, label, monthName, dayStr] = m;
    const mi = monthIndex(monthName);
    const day = Number(dayStr);
    // Pick whichever of the period's start/end year makes this date fall inside the period.
    const candidates = [period.startYear, period.endYear];
    let chosenYear = candidates[0];
    for (const year of candidates) {
      const iso = isoDate(year, mi, day);
      if (iso >= period.startDate && iso <= period.endDate) {
        chosenYear = year;
        break;
      }
    }
    results.push({ label: label.trim(), date: isoDate(chosenYear, mi, day) });
  }
  return results;
}

function main() {
  const wb = XLSX.readFile(FILE);
  const ws = wb.Sheets["Sheet2"];
  if (!ws) throw new Error('Sheet "Sheet2" not found in Payroll Dates file');
  const range = XLSX.utils.decode_range(ws["!ref"]);

  const text = (r, c) => {
    const cell = ws[XLSX.utils.encode_cell({ r, c })];
    return cell && cell.v !== undefined && cell.v !== null ? String(cell.v).trim() : "";
  };

  // Row 1 (0-indexed row 0) is the header. Data starts at row index 1.
  // Only rows where column A (PAY PERIOD) is non-empty are real data rows -
  // the sheet has some stray blank rows near the bottom (see row 34-40).
  const dataRows = [];
  for (let r = 1; r <= range.e.r; r++) {
    if (text(r, 0)) dataRows.push(r);
  }
  if (dataRows.length === 0) throw new Error("No pay-period rows found");

  // Anchor: the first row's period is known from the real spreadsheet
  // ("March 9-23, 2026"). Every subsequent row follows the fixed cycle.
  let cursor = { year: 2026, monthIndex0: 2, day: 9 };
  const anchorText = text(dataRows[0], 0);
  if (!/march\s*9/i.test(anchorText)) {
    throw new Error(
      `Expected the schedule to start at "March 9, 2026" but first row is "${anchorText}". ` +
        "The company issued a new schedule - update the anchor date in this script."
    );
  }

  const periods = dataRows.map((r) => {
    const start = cursor;
    const end = periodEnd(start);
    cursor = nextPeriodStart(start.year, start.monthIndex0, start.day);

    const period = {
      startDate: isoDate(start.year, start.monthIndex0, start.day),
      endDate: isoDate(end.year, end.monthIndex0, end.day),
      startYear: start.year,
      endYear: end.year,
    };

    const dueByText = text(r, 1);
    const statText = text(r, 2);
    const { primary, weekendAlternate } = parseDueBy(dueByText, end.year);

    return {
      startDate: period.startDate,
      endDate: period.endDate,
      dueDateTime: primary,
      dueDateTimeIfWorkingWeekend: weekendAlternate,
      statHolidays: parseStatHolidays(statText, period),
      sourceText: { payPeriod: text(r, 0), dueBy: dueByText, statHoliday: statText },
    };
  });

  fs.mkdirSync(path.dirname(OUT_FILE), { recursive: true });
  fs.writeFileSync(OUT_FILE, JSON.stringify({ sourceFile: "Payroll Dates (2).xlsx", periods }, null, 2) + "\n");

  console.log(`Wrote ${periods.length} periods to ${path.relative(ROOT, OUT_FILE)}`);
  for (const p of periods) {
    const stat = p.statHolidays.map((h) => `${h.label}(${h.date})`).join(", ");
    console.log(`  ${p.startDate} -> ${p.endDate}  due ${p.dueDateTime}${stat ? "  STAT: " + stat : ""}`);
  }
}

main();
