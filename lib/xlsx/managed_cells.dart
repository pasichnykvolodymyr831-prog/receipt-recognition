/// The A1 addresses every engine writes to, one list per sheet, plus the
/// sheet-name lists for the Mileage Report workbook. This is the single
/// source of truth shared by the style-integrity check (excel_integrity.dart)
/// and the style healer (style_heal.dart), so the two can never drift apart
/// on "which cells/sheets does the app manage" vs. "every sheet that exists".
library;

import 'mileage_report_engine.dart';
import 'timesheet_engine.dart';

const mileageHiddenSheets = ['Truman Dev', 'Lionsworthe', 'Taphouse', 'Metro', 'Sheet1'];
const mileageVisibleSheets = ['Truman Homes', 'Driving Details'];

// Row-range bounds reuse MileageReportEngine's/TimesheetEngine's own
// constants rather than repeating 8/27/2/18/8/38 as bare literals (Пакет
// 34, audit 2026-08-18) -- those were the single source of truth already,
// this file (and excel_integrity.dart/raw_style_patch.dart, which import
// them from here or the engines directly) just weren't using them, so a
// future row-range change had no way to stay in sync across all of them.
final List<String> mileageTrumanHomesManagedCells = [
  for (var row = MileageReportEngine.firstDataRow; row <= MileageReportEngine.lastDataRow; row++)
    for (final col in ['A', 'B', 'D', 'E', 'K']) '$col$row',
];

final List<String> mileageDrivingDetailsManagedCells = [
  for (var row = MileageReportEngine.firstDrivingRow; row <= MileageReportEngine.lastDrivingRow; row++)
    for (final col in ['A', 'B', 'C']) '$col$row',
];

final List<String> timesheetManagedCells = [
  for (var row = TimesheetEngine.firstDayRow; row <= TimesheetEngine.lastDayRow; row++)
    for (final col in ['B', 'C', 'D', 'E', 'F', 'G', 'H']) '$col$row',
  'H39',
];
