import 'package:excel/excel.dart';

import 'managed_cells.dart';
import 'mileage_report_engine.dart';
import 'timesheet_engine.dart';
import 'xlsx_raw_inspect.dart';

/// Result of an integrity check (section 13.2): whether the write is safe
/// to keep, a human-readable list of fatal problems if not (formulas turned
/// into values, hidden sheets touched, file won't open -- these block the
/// write), and a separate list of non-fatal style warnings (border/font/
/// number_format drift from the template -- logged, never blocks a write,
/// since [healMileageReportStyles]/[healTimesheetStyles] in style_heal.dart
/// already run before this check and are expected to have fixed it; a
/// residual warning here means healing couldn't fully match the template,
/// e.g. the known text-in-a-time-formatted-cell number_format quirk).
class IntegrityReport {
  final bool ok;
  final List<String> issues;
  final List<String> styleWarnings;
  const IntegrityReport(this.ok, this.issues, {this.styleWarnings = const []});
}

/// Verifies a freshly-written Mileage Report workbook: the 5 hidden sheets
/// must stay hidden, and their content must match [template] exactly, and
/// every formula cell in the Truman Homes / Driving Details sheets must
/// still be a formula (not baked into a plain number).
///
/// [newBytes] is deliberately re-decoded from the already-encoded bytes
/// about to be written to disk, rather than checking the in-memory workbook
/// object the caller healed -- this is what catches corruption introduced
/// by the encode step itself (e.g. a known `excel`-package bug where a
/// cell's style silently reverts on encode even when the in-memory
/// [CellStyle] was verified correct beforehand). [template] is compared
/// against directly (not "the file as it was right before this write") --
/// hidden sheets are copied verbatim from the template once, at period-file
/// creation, and the app never touches them again, so "matches the
/// template" and "unchanged since last write" are equivalent, and the
/// former is the stronger guarantee (it also catches drift from any
/// earlier write, not just this one).
IntegrityReport checkMileageReportIntegrity({
  required List<int> newBytes,
  required Excel template,
}) {
  final issues = <String>[];
  final styleWarnings = <String>[];

  Excel newExcel;
  try {
    newExcel = Excel.decodeBytes(newBytes);
  } catch (e) {
    return IntegrityReport(false, ['File does not open: $e']);
  }

  final hiddenStates = readSheetHiddenStates(newBytes);
  for (final name in mileageHiddenSheets) {
    if (hiddenStates[name] != true) {
      issues.add('Sheet "$name" is not hidden (expected hidden)');
    }
    final same = _sheetsEqual(template.sheets[name], newExcel.sheets[name]);
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
  final templateSheet = template.sheets['Truman Homes'];
  if (sheet == null) {
    issues.add('Sheet "Truman Homes" missing');
  } else {
    for (var row = MileageReportEngine.firstDataRow; row <= MileageReportEngine.lastDataRow; row++) {
      _expectFormula(sheet, templateSheet, 'I$row', issues);
      _expectFormula(sheet, templateSheet, 'L$row', issues);
    }
    for (final col in ['C', 'D', 'E', 'F', 'G', 'H', 'K']) {
      _expectFormula(sheet, templateSheet, '${col}28', issues);
    }
    _expectFormula(sheet, templateSheet, 'L28', issues);
    _expectNotFormula(sheet, 'I28', issues); // hardcoded 0 by design, section 6.1
    _expectFormula(sheet, templateSheet, 'M30', issues);

    if (templateSheet != null) {
      for (final a1 in mileageTrumanHomesManagedCells) {
        _expectStylePreserved(sheet, templateSheet, a1, styleWarnings);
      }
      _expectMergeRangesPreserved(newExcel, template, 'Truman Homes', issues);
    }
  }

  final drivingSheet = newExcel.sheets['Driving Details'];
  final templateDrivingSheet = template.sheets['Driving Details'];
  if (drivingSheet == null) {
    issues.add('Sheet "Driving Details" missing');
  } else {
    for (var row = MileageReportEngine.firstDrivingRow; row <= MileageReportEngine.lastDrivingRow; row++) {
      _expectFormula(drivingSheet, templateDrivingSheet, 'D$row', issues);
    }
    _expectFormula(drivingSheet, templateDrivingSheet, 'C19', issues);
    _expectFormula(drivingSheet, templateDrivingSheet, 'D19', issues);

    if (templateDrivingSheet != null) {
      for (final a1 in mileageDrivingDetailsManagedCells) {
        _expectStylePreserved(drivingSheet, templateDrivingSheet, a1, styleWarnings);
      }
      _expectMergeRangesPreserved(newExcel, template, 'Driving Details', issues);
    }
  }

  return IntegrityReport(issues.isEmpty, issues, styleWarnings: styleWarnings);
}

/// Verifies a freshly-written Timesheet workbook opens correctly, that its
/// Item# column (A8:A38, fixed values 1-31 from the template) is intact,
/// and that every cell the app writes to still carries [template]'s
/// border/font/number_format -- as a non-fatal warning, since
/// style_heal.dart is expected to have fixed it before this check runs.
/// See [checkMileageReportIntegrity] for why [newBytes] is re-decoded here
/// rather than reusing the caller's in-memory workbook object.
IntegrityReport checkTimesheetIntegrity({
  required List<int> newBytes,
  required Excel template,
}) {
  final issues = <String>[];
  final styleWarnings = <String>[];
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

  for (var row = TimesheetEngine.firstDayRow; row <= TimesheetEngine.lastDayRow; row++) {
    final expectedItem = row - TimesheetEngine.firstDayRow + 1;
    final value = sheet.cell(CellIndex.indexByColumnRow(columnIndex: 0, rowIndex: row - 1)).value;
    final actual = value is IntCellValue
        ? value.value
        : (value is DoubleCellValue ? value.value.round() : null);
    if (actual != expectedItem) {
      issues.add('Item# at A$row expected $expectedItem, found $actual');
    }
  }

  final templateSheet = template.sheets['Sheet1'];
  if (templateSheet != null) {
    for (final a1 in timesheetManagedCells) {
      _expectStylePreserved(sheet, templateSheet, a1, styleWarnings);
    }
  }

  return IntegrityReport(issues.isEmpty, issues, styleWarnings: styleWarnings);
}

/// Verifies [a1] is still a formula cell (section 13 п.8's minimum
/// guarantee, always checked) and, when [templateSheet] is given and its
/// own cell at [a1] is itself a formula, that the formula *text* still
/// matches the template's exactly -- not just "is a formula" (a corrupted
/// or shifted formula, e.g. a term dropped from `+H8+G8+...` or a column
/// ref off by one, would previously pass this check silently). The app
/// never writes formula strings itself (they live in the template and are
/// only ever carried through re-encode), so the template is always the
/// correct reference text to compare against.
void _expectFormula(Sheet sheet, Sheet? templateSheet, String a1, List<String> issues) {
  final value = sheet.cell(CellIndex.indexByString(a1)).value;
  if (value is! FormulaCellValue) {
    issues.add('Expected formula at $a1 but found ${value.runtimeType}');
    return;
  }
  final templateValue = templateSheet?.cell(CellIndex.indexByString(a1)).value;
  if (templateValue is FormulaCellValue && templateValue.formula != value.formula) {
    issues.add('Formula at $a1 changed: expected "${templateValue.formula}", found "${value.formula}"');
  }
}

void _expectNotFormula(Sheet sheet, String a1, List<String> issues) {
  final value = sheet.cell(CellIndex.indexByString(a1)).value;
  if (value is FormulaCellValue) {
    issues.add('Expected a plain value at $a1 (by design) but found a formula');
  }
}

/// Verifies that [a1] on [sheet] still has the border/font/number_format it
/// had at [a1] on [templateSheet]. Guards against the `excel` package
/// silently resetting a cell's style to its default whenever a value is
/// written to it (see [setCellValue] in cell_value_utils.dart).
void _expectStylePreserved(Sheet sheet, Sheet templateSheet, String a1, List<String> issues) {
  final cell = sheet.cell(CellIndex.indexByString(a1));
  final style = cell.cellStyle;
  final templateStyle = templateSheet.cell(CellIndex.indexByString(a1)).cellStyle;
  if (style == templateStyle) return;

  if (templateStyle == null) {
    issues.add('Cell $a1 has a style but the template did not');
    return;
  }
  if (style == null) {
    issues.add('Cell $a1 lost its style entirely (expected border/font/number_format from template)');
    return;
  }
  // Skip the number_format comparison when the template's format can't
  // actually hold this cell's value type (e.g. a "h:mm" time format on a
  // cell the app fills with a formatted text string like "8am" -- Timesheet
  // stores Start/Lunch/Finish as text, not real Excel time values). Excel
  // ignores number formats on text, so re-deriving a compatible format
  // there isn't a style regression; the `excel` package itself falls back
  // to General for exactly this reason when it re-reads such a cell.
  //
  // `NumFormat.accepts(null)` is always `true` for every subclass in the
  // `excel` package (v4.0.6) -- so this exemption must require a real,
  // non-null value before applying, or it silently stops checking
  // number_format on every not-yet-written managed cell (audit 2026-08-18,
  // Пакет 16).
  final cellValue = cell.value;
  final formatExempt = cellValue != null && !templateStyle.numberFormat.accepts(cellValue);
  if (!formatExempt && style.numberFormat.formatCode != templateStyle.numberFormat.formatCode) {
    issues.add(
        'Cell $a1 number_format changed: expected "${templateStyle.numberFormat.formatCode}", found "${style.numberFormat.formatCode}"');
  }
  if (style.fontFamily != templateStyle.fontFamily || style.fontSize != templateStyle.fontSize) {
    issues.add(
        'Cell $a1 font changed: expected ${templateStyle.fontFamily} ${templateStyle.fontSize}pt, found ${style.fontFamily} ${style.fontSize}pt');
  }
  if (style.topBorder != templateStyle.topBorder ||
      style.bottomBorder != templateStyle.bottomBorder ||
      style.leftBorder != templateStyle.leftBorder ||
      style.rightBorder != templateStyle.rightBorder) {
    issues.add('Cell $a1 border changed from the template');
  }
}

/// Verifies [sheetName]'s declared merge ranges (section 13 п.6) still
/// exactly match [template]'s -- not "the continuation cell exists"
/// (already guarded by raw_style_patch.dart's `_insertMissingMergedCells`,
/// defect #6), but "the merged range itself is the same one the template
/// declares" (e.g. `I8:J8`). A future write path that silently un-merges a
/// range, or merges the wrong one, would open fine and pass every other
/// check today -- exactly the "looks correct, wrong in real Excel" failure
/// class this project has repeatedly hit only on a real device file.
void _expectMergeRangesPreserved(Excel newExcel, Excel template, String sheetName, List<String> issues) {
  final expected = template.getMergedCells(sheetName).toSet();
  final actual = newExcel.getMergedCells(sheetName).toSet();
  final missing = expected.difference(actual);
  final extra = actual.difference(expected);
  if (missing.isNotEmpty) {
    issues.add('Sheet "$sheetName" lost merge range(s) from the template: ${missing.join(", ")}');
  }
  if (extra.isNotEmpty) {
    issues.add('Sheet "$sheetName" has unexpected merge range(s) not in the template: ${extra.join(", ")}');
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
