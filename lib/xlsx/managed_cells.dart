/// The A1 addresses every engine writes to, one list per sheet, plus the
/// sheet-name lists for the Mileage Report workbook. This is the single
/// source of truth shared by the style-integrity check (excel_integrity.dart)
/// and the style healer (style_heal.dart), so the two can never drift apart
/// on "which cells/sheets does the app manage" vs. "every sheet that exists".
library;

const mileageHiddenSheets = ['Truman Dev', 'Lionsworthe', 'Taphouse', 'Metro', 'Sheet1'];
const mileageVisibleSheets = ['Truman Homes', 'Driving Details'];

final List<String> mileageTrumanHomesManagedCells = [
  for (var row = 8; row <= 27; row++)
    for (final col in ['A', 'B', 'D', 'E', 'K']) '$col$row',
];

final List<String> mileageDrivingDetailsManagedCells = [
  for (var row = 2; row <= 18; row++)
    for (final col in ['A', 'B', 'C']) '$col$row',
];

final List<String> timesheetManagedCells = [
  for (var row = 8; row <= 38; row++)
    for (final col in ['B', 'C', 'D', 'E', 'F', 'G', 'H']) '$col$row',
  'H39',
];
