import type { PayPeriod } from "../types/models";
import { fromIsoDate } from "./isoDate";

const MONTH_ABBREV = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"];

function pad2(n: number): string {
  return String(n).padStart(2, "0");
}

/** Matches the templates' own label style, e.g. "Jul 24 - Aug 07 2026". */
export function formatPayPeriodLabel(period: PayPeriod): string {
  const start = fromIsoDate(period.startDate);
  const end = fromIsoDate(period.endDate);
  return `${MONTH_ABBREV[start.getMonth()]} ${start.getDate()} - ${MONTH_ABBREV[end.getMonth()]} ${pad2(
    end.getDate()
  )} ${end.getFullYear()}`;
}
