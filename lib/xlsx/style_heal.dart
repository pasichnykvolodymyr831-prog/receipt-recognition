import 'package:excel/excel.dart';

import 'managed_cells.dart';

/// Reapplies the pristine template's border/font/number_format to *every*
/// cell of *every* sheet (visible and hidden) in the workbook being written
/// -- not just the cells the app is allowed to write to.
///
/// This exists to self-heal period files damaged by the `excel` package's
/// own re-save behavior: on every full workbook re-encode, `excel` silently
/// drops part of the formatting on cells the app never touched at all
/// (headers, labels, hidden-sheet content) -- measured on a real period
/// file at 910 mismatched cells before any healing existed, 176 after a
/// first fix that only healed the ~50 cells the app actually writes to
/// (managed_cells.dart). Since the app never writes a *value* into any of
/// those still-damaged cells, reapplying the template's style to the whole
/// sheet on every write is safe: there is no user data in those cells for
/// this to clobber, only stale formatting to restore.
class TemplateStyleCache {
  // Keyed by "<workbook>::<sheetName>", not just sheet name -- the Mileage
  // Report workbook has its own hidden sheet named "Sheet1" (see
  // managed_cells.dart), which would otherwise collide with the Timesheet
  // workbook's single "Sheet1".
  static final Map<String, Map<String, CellStyle?>> _cache = {};

  /// Builds (once) and returns the `{a1 -> style}` map for every cell of
  /// [templateSheet], covering the sheet's full used range
  /// (0..maxRows x 0..maxColumns). The bundled template asset never changes
  /// at runtime, so this is safe to cache for the lifetime of the app --
  /// rebuilding it on every write is the expensive part once the healed
  /// range grows from ~50 cells to a whole multi-sheet workbook.
  static Map<String, CellStyle?> forSheet(Sheet templateSheet, String cacheKey) {
    return _cache.putIfAbsent(cacheKey, () {
      final styles = <String, CellStyle?>{};
      for (var r = 0; r < templateSheet.maxRows; r++) {
        for (var c = 0; c < templateSheet.maxColumns; c++) {
          final idx = CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);
          styles[idx.cellId] = templateSheet.cell(idx).cellStyle;
        }
      }
      return styles;
    });
  }
}

/// Heals the visible sheets (Truman Homes, Driving Details) on every write.
/// [includeHiddenSheets] additionally heals the 5 hidden sheets -- pass
/// true only when creating a period file for the first time. Hidden-sheet
/// content is copied verbatim from the template and the app never writes
/// to it again, so a one-time heal at creation is enough; re-healing (and
/// re-touching) potentially large hidden sheets on every single receipt/
/// trip/timesheet write was measured to be the dominant cost of a save on
/// a real device (worst case: a write that never completed).
void healMileageReportStyles(Excel excel, Excel template, {bool includeHiddenSheets = false}) {
  final sheetNames = includeHiddenSheets ? [...mileageVisibleSheets, ...mileageHiddenSheets] : mileageVisibleSheets;
  for (final name in sheetNames) {
    final sheet = excel.sheets[name];
    final templateSheet = template.sheets[name];
    if (sheet == null || templateSheet == null) continue;
    _healAllCells(sheet, templateSheet, 'mileage::$name');
  }
}

void healTimesheetStyles(Excel excel, Excel template) {
  final sheet = excel.sheets['Sheet1'];
  final templateSheet = template.sheets['Sheet1'];
  if (sheet != null && templateSheet != null) {
    _healAllCells(sheet, templateSheet, 'timesheet::Sheet1');
  }
}

void _healAllCells(Sheet sheet, Sheet templateSheet, String cacheKey) {
  final styles = TemplateStyleCache.forSheet(templateSheet, cacheKey);
  for (final entry in styles.entries) {
    final templateStyle = entry.value;
    if (templateStyle == null) continue;
    final cell = sheet.cell(CellIndex.indexByString(entry.key));
    if (cell.cellStyle != templateStyle) {
      cell.cellStyle = templateStyle;
    }
  }
}
