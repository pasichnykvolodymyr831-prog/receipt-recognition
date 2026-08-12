import 'package:excel/excel.dart';

import 'xlsx_raw_inspect.dart';

/// Result of an integrity check (section 13.2): whether the write is safe
/// to keep, and a human-readable list of what failed if not.
class IntegrityReport {
  final bool ok;
  final List<String> issues;
  const IntegrityReport(this.ok, this.issues);
  factory IntegrityReport.success() => const IntegrityReport(true, []);
}

const mileageHiddenSheets = ['Truman Dev', 'Lionsworthe', 'Taphouse', 'Metro', 'Sheet1'];
const mileageVisibleSheets = ['Truman Homes', 'Driving Details'];

/// Verifies a freshly-written Mileage Report workbook against the copy it
/// was derived from: the 5 hidden sheets must stay hidden and untouched,
/// and every formula cell in the Truman Homes / Driving Details sheets
/// must still be a formula (not baked into a plain number).
IntegrityReport checkMileageReportIntegrity({
  required List<int> originalBytes,
  required List<int> newBytes,
}) {
  final issues = <String>[];

  Excel newExcel;
  try {
    newExcel = Excel.decodeBytes(newBytes);
  } catch (e) {
    return IntegrityReport(false, ['File does not open: $e']);
  }

  Excel originalExcel;
  try {
    originalExcel = Excel.decodeBytes(originalBytes);
  } catch (e) {
    return IntegrityReport(false, ['Original reference file does not open: $e']);
  }

  final hiddenStates = readSheetHiddenStates(newBytes);
  for (final name in mileageHiddenSheets) {
    if (hiddenStates[name] != true) {
      issues.add('Sheet "$name" is not hidden (expected hidden)');
    }
    final same = _sheetsEqual(originalExcel.sheets[name], newExcel.sheets[name]);
    if (!same) {
      issues.add('Hidden sheet "$name" content changed');
    }
  }
  for (final name in mileageVisibleSheets) {
    if (hiddenStates[name] != false) {
      issues.add('Sheet "$name" is not visible (expected visible)');
    }
  }

  final sheet = newExcel.sheets['Truman Homes'];
  if (sheet == null) {
    issues.add('Sheet "Truman Homes" missing');
  } else {
    for (var row = 8; row <= 27; row++) {
      _expectFormula(sheet, 'I$row', issues);
      _expectFormula(sheet, 'L$row', issues);
    }
    for (final col in ['C', 'D', 'E', 'F', 'G', 'H', 'K']) {
      _expectFormula(sheet, '${col}28', issues);
    }
    _expectFormula(sheet, 'L28', issues);
    _expectNotFormula(sheet, 'I28', issues); // hardcoded 0 by design, section 6.1
    _expectFormula(sheet, 'M30', issues);
  }

  final drivingSheet = newExcel.sheets['Driving Details'];
  if (drivingSheet == null) {
    issues.add('Sheet "Driving Details" missing');
  } else {
    for (var row = 2; row <= 18; row++) {
      _expectFormula(drivingSheet, 'D$row', issues);
    }
    _expectFormula(drivingSheet, 'C19', issues);
    _expectFormula(drivingSheet, 'D19', issues);
  }

  return issues.isEmpty ? IntegrityReport.success() : IntegrityReport(false, issues);
}

/// Verifies a freshly-written Timesheet workbook opens correctly and that
/// its Item# column (A8:A38, fixed values 1-31 from the template) is intact.
IntegrityReport checkTimesheetIntegrity({required List<int> newBytes}) {
  final issues = <String>[];
  Excel newExcel;
  try {
    newExcel = Excel.decodeBytes(newBytes);
  } catch (e) {
    return IntegrityReport(false, ['File does not open: $e']);
  }

  final sheet = newExcel.sheets['Sheet1'];
  if (sheet == null) {
    return IntegrityReport(false, ['Sheet "Sheet1" missing']);
  }

  for (var row = 8; row <= 38; row++) {
    final expectedItem = row - 8 + 1;
    final value = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row - 1)).value;
    final actual = value is IntCellValue
        ? value.value
        : (value is DoubleCellValue ? value.value.round() : null);
    if (actual != expectedItem) {
      issues.add('Item# at A$row expected $expectedItem, found $actual');
    }
  }

  return issues.isEmpty ? IntegrityReport.success() : IntegrityReport(false, issues);
}

void _expectFormula(Sheet sheet, String a1, List<String> issues) {
  final value = sheet.cell(CellIndex.indexByString(a1)).value;
  if (value is! FormulaCellValue) {
    issues.add('Expected formula at $a1 but found ${value.runtimeType}');
  }
}

void _expectNotFormula(Sheet sheet, String a1, List<String> issues) {
  final value = sheet.cell(CellIndex.indexByString(a1)).value;
  if (value is FormulaCellValue) {
    issues.add('Expected a plain value at $a1 (by design) but found a formula');
  }
}

bool _sheetsEqual(Sheet? a, Sheet? b) {
  if (a == null || b == null) return identical(a, b);
  final maxRows = a.maxRows > b.maxRows ? a.maxRows : b.maxRows;
  final maxCols = a.maxColumns > b.maxColumns ? a.maxColumns : b.maxColumns;
  for (var r = 0; r < maxRows; r++) {
    for (var c = 0; c < maxCols; c++) {
      final va = r < a.maxRows && c < a.maxColumns
          ? a.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).value
          : null;
      final vb = r < b.maxRows && c < b.maxColumns
          ? b.cell(CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r)).value
          : null;
      if (va != vb) return false;
    }
  }
  return true;
}
