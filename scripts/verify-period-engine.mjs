#!/usr/bin/env node
/**
 * Sanity checks for the payroll period engine against the real bundled
 * schedule (src/assets/schema/payrollSchedule.json).
 *
 * Run with: node --experimental-strip-types scripts/verify-period-engine.mjs
 */
import {
  getPeriodBoundaries,
  getPeriodForDate,
  resolvePeriod,
  effectiveDueDateTime,
  isStatHoliday,
  isWeekend,
  generateDefaultTimesheetRows,
} from "../src/services/payroll/periodEngine.ts";
import { isPeriodExpired } from "../src/services/storage/retentionSweep.ts";

let failures = 0;
function check(label, cond, detail) {
  if (cond) {
    console.log(`  OK   ${label}`);
  } else {
    failures++;
    console.log(`  FAIL ${label}${detail ? " - " + detail : ""}`);
  }
}

console.log("== Period boundaries ==");
check(
  "mid-period date (Aug 15) -> Aug 9-23",
  JSON.stringify(getPeriodBoundaries(new Date(2026, 7, 15))) ===
    JSON.stringify({ startDate: "2026-08-09", endDate: "2026-08-23" })
);
check(
  "late-period date (Aug 30) -> Aug 24-Sep 8",
  JSON.stringify(getPeriodBoundaries(new Date(2026, 7, 30))) ===
    JSON.stringify({ startDate: "2026-08-24", endDate: "2026-09-08" })
);
check(
  "early-month date (Aug 3) -> Jul 24-Aug 8",
  JSON.stringify(getPeriodBoundaries(new Date(2026, 7, 3))) ===
    JSON.stringify({ startDate: "2026-07-24", endDate: "2026-08-08" })
);
check(
  "year-boundary date (Jan 3, 2027) -> Dec24,2026-Jan8,2027",
  JSON.stringify(getPeriodBoundaries(new Date(2027, 0, 3))) ===
    JSON.stringify({ startDate: "2026-12-24", endDate: "2027-01-08" })
);

console.log("\n== Real due-date exceptions ==");
const augPeriod = resolvePeriod("2026-08-09", "2026-08-23");
check("Aug 9-23 period due date is Aug 21 (2 days early, real exception)", augPeriod.dueDateTime === "2026-08-21T16:30:00", augPeriod.dueDateTime);
check("Aug 9-23 period is NOT flagged as generated (it's real data)", augPeriod.isGenerated === false);

const novPeriod = resolvePeriod("2026-10-24", "2026-11-08");
check("Oct24-Nov8 period due date is Nov 6 (real exception)", novPeriod.dueDateTime === "2026-11-06T16:30:00", novPeriod.dueDateTime);

console.log("\n== Generated fallback beyond the bundled calendar ==");
const farFuture = getPeriodForDate(new Date(2030, 5, 15));
check("far-future period is flagged as generated", farFuture.isGenerated === true);
check("far-future period has a sensible fallback due date", farFuture.dueDateTime === `${farFuture.endDate}T16:30:00`, farFuture.dueDateTime);
check("far-future period has no known STAT days", farFuture.statHolidayDates.length === 0);

console.log("\n== Weekend due-date alternate ==");
const janPeriod = resolvePeriod("2026-12-24", "2027-01-08"); // due Jan 8 2027 = Friday, no weekend clause on this one
check("Dec24-Jan8 due date has no weekend alt (Jan 8 2027 is a Friday)", janPeriod.dueDateTimeIfWorkingWeekend === null);
const julPeriod = resolvePeriod("2026-07-24", "2026-08-08"); // due Aug 8 2026 = Saturday -> should use Aug 10 alt
check("Jul24-Aug8 primary due date (Aug 8, 2026) really is a Saturday", new Date(julPeriod.dueDateTime).getDay() === 6);
check(
  "effectiveDueDateTime picks the weekend alternate (Aug 10 8:30am)",
  effectiveDueDateTime(julPeriod) === "2026-08-10T08:30:00",
  effectiveDueDateTime(julPeriod)
);
check(
  "effectiveDueDateTime falls back to primary when it's not a weekend",
  effectiveDueDateTime(augPeriod) === augPeriod.dueDateTime
);

console.log("\n== STAT holidays / weekends ==");
check("isWeekend true for a Saturday", isWeekend("2026-08-08") === true);
check("isWeekend false for a Wednesday", isWeekend("2026-08-05") === false);
check("isStatHoliday true for Heritage Day within Jul24-Aug8 period", isStatHoliday("2026-08-03", julPeriod) === true);
check("isStatHoliday false for a normal weekday", isStatHoliday("2026-08-04", julPeriod) === false);

console.log("\n== Default Timesheet rows ==");
const rows = generateDefaultTimesheetRows(julPeriod);
check("covers every day of the period (16 days for Jul24-Aug8)", rows.length === 16, rows.length);
const aug3 = rows.find((r) => r.date === "2026-08-03"); // Heritage Day, a Monday
check("STAT holiday weekday (Aug 3) is blank", aug3.startMinutes === null);
const aug8 = rows.find((r) => r.date === "2026-08-08"); // Saturday
check("weekend day (Aug 8) is blank", aug8.startMinutes === null);
const jul27 = rows.find((r) => r.date === "2026-07-27"); // ordinary Monday
check("ordinary weekday (Jul 27) defaults to 8:00 start", jul27.startMinutes === 8 * 60);
check("ordinary weekday defaults to 30-min lunch", jul27.lunchBreakMinutes === 30);
check("ordinary weekday defaults to 16:30 finish", jul27.finishMinutes === 16 * 60 + 30);
check("ordinary weekday has no default coffee break", jul27.coffeeBreakMinutes === null);

console.log("\n== Retention sweep expiry logic ==");
check("3-month retention: period ended 2 months ago is NOT expired", isPeriodExpired("2026-06-08", "3m", new Date(2026, 7, 1)) === false);
check("3-month retention: period ended 4 months ago IS expired", isPeriodExpired("2026-06-08", "3m", new Date(2026, 10, 1)) === true);
check("'forever' retention: never expires", isPeriodExpired("2020-01-01", "forever", new Date(2030, 0, 1)) === false);
check("'none' retention: expired the day after it ends", isPeriodExpired("2026-08-08", "none", new Date(2026, 7, 9)) === true);
check("'none' retention: not yet expired on its own end date", isPeriodExpired("2026-08-08", "none", new Date(2026, 7, 8)) === false);

console.log(`\n${failures === 0 ? "ALL CHECKS PASSED" : failures + " CHECK(S) FAILED"}`);
process.exit(failures === 0 ? 0 : 1);
