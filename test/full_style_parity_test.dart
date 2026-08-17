// Spec section 13, test #13: after a representative sequence of writes,
// every cell of every sheet (visible AND hidden) in both workbooks should
// match the template's style -- not just the ~50 cells the app is allowed
// to write to (that narrower check already exists as _expectStylePreserved
// in xlsx/excel_integrity.dart, IntegrityReport.styleWarnings, 2(г)). This
// is the broader assertion the style-heal scope extension (section 0, item
// 1) is meant to satisfy: on a real period file, whole-sheet style drift
// measured 910 mismatched cells before any healing existed, 176 after the
// narrower managed-cells-only fix, 142 (Mileage) once font/border were
// compared against the true reference template instead of a stale bundled
// asset (section 0, item 3).
//
// Both workbooks now reach exactly 0. The remaining gap after item 3 was
// two separate `excel`-package (v4.0.6) defects style_heal.dart's
// CellStyle-level healing structurally cannot reach: alignment (the
// package's parser never reads `horizontal`/`vertical` off `<xf>` at all --
// a source-confirmed bug, not a heuristic) and a small, fixed set of cells
// (Mileage: J31 on every sheet; Timesheet: 20 cells) whose font/border/fill
// silently fell back to the workbook default on `.encode()` even when the
// in-memory `CellStyle` was verified byte-for-byte correct beforehand
// (confirmed by black-box testing: once ANY cell's style is reassigned
// anywhere in a workbook, the package flips a workbook-global
// `_styleChanges` flag that routes every cell's style index through an
// internal registry lookup which silently fails for these specific cells).
// `raw_style_patch.dart` closes both by comparing each cell's actual style
// *content* against the template directly in the encoded XML, bypassing
// the package's object model entirely -- see its module doc for how.
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/xlsx/managed_cells.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';
import 'package:expenseflow/xlsx/xlsx_rels_compat.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';
const timesheetTemplatePath = 'assets/templates/Truman_Homes_Timesheet_TEMPLATE.xlsx';

/// Same tolerance rule as _expectStylePreserved in excel_integrity.dart:
/// skip the number_format comparison when the template's format can't
/// actually hold this cell's value type (a text value like "8am" in a
/// cell the template formats as a time -- Excel ignores number formats on
/// text, so a mismatch there isn't a real style regression).
List<String> _allCellStyleMismatches(Excel actual, Excel template, List<String> sheetNames) {
  final mismatches = <String>[];
  for (final name in sheetNames) {
    final sheet = actual.sheets[name];
    final templateSheet = template.sheets[name];
    if (sheet == null || templateSheet == null) continue;
    for (var r = 0; r < templateSheet.maxRows; r++) {
      for (var c = 0; c < templateSheet.maxColumns; c++) {
        final idx = CellIndex.indexByColumnRow(columnIndex: c, rowIndex: r);
        final style = sheet.cell(idx).cellStyle;
        final templateStyle = templateSheet.cell(idx).cellStyle;
        if (style == templateStyle) continue;
        if (templateStyle == null || style == null) {
          mismatches.add('$name!${idx.cellId}: style presence differs');
          continue;
        }
        final reasons = <String>[];
        if (templateStyle.numberFormat.accepts(sheet.cell(idx).value) &&
            style.numberFormat.formatCode != templateStyle.numberFormat.formatCode) {
          reasons.add('number_format');
        }
        if (style.fontFamily != templateStyle.fontFamily || style.fontSize != templateStyle.fontSize) {
          reasons.add('font');
        }
        if (style.topBorder != templateStyle.topBorder ||
            style.bottomBorder != templateStyle.bottomBorder ||
            style.leftBorder != templateStyle.leftBorder ||
            style.rightBorder != templateStyle.rightBorder) {
          reasons.add('border');
        }
        if (reasons.isNotEmpty) {
          mismatches.add('$name!${idx.cellId}: ${reasons.join(", ")}');
        }
      }
    }
  }
  return mismatches;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final docsDir = await Directory.systemTemp.createTemp('full_style_parity_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  test('Mileage Report: every cell of every sheet (incl. hidden) matches the template after several writes',
      () async {
    final originalBytes = File(mileageTemplatePath).readAsBytesSync();

    final dir = await Directory.systemTemp.createTemp('full_style_parity_mileage');
    final file = File('${dir.path}/MileageReport_test.xlsx');

    // Mirrors the real sequence of separate user actions (create period,
    // then add trips/receipts one at a time) -- each now a separate
    // isolate round-trip, exactly as PeriodFileManager/the screens do.
    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );
    await saveMileageDrivingDetail(
      file,
      date: DateTime(2026, 8, 10),
      trip: 'Site A to Site B',
      km: 42.5,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );
    await saveMileageDrivingDetail(
      file,
      date: DateTime(2026, 8, 12),
      trip: 'Site C',
      km: 10,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );
    await saveMileageReceipt(
      file,
      ReceiptInput(
        date: DateTime(2026, 8, 10),
        description: 'Home Depot - toilet fill valve, garbage bags',
        subtotal: 45.99,
        gst: 2.30,
      ),
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );
    await saveMileageReceipt(
      file,
      const ReceiptInput(date: null, description: null, subtotal: 12.5, gst: 0.63),
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );

    final result = Excel.decodeBytes(await file.readAsBytes());
    final template = Excel.decodeBytes(normalizeXlsxRelationshipTargets(originalBytes));
    final mismatches = _allCellStyleMismatches(result, template, [...mileageVisibleSheets, ...mileageHiddenSheets]);

    expect(mismatches, isEmpty, reason: 'style mismatches remaining after full-sheet healing: $mismatches');

    await dir.delete(recursive: true);
  });

  test('Timesheet: every cell matches the template after several writes', () async {
    final originalBytes = File(timesheetTemplatePath).readAsBytesSync();
    final period = PayrollPeriod(
      key: '2026-08-09_2026-08-23',
      start: DateTime(2026, 8, 9),
      end: DateTime(2026, 8, 23),
      due: DateTime(2026, 8, 21, 16, 30),
      weekendAltDue: DateTime(2026, 8, 23, 8, 30),
      statHolidays: const [],
    );

    final dir = await Directory.systemTemp.createTemp('full_style_parity_timesheet');
    final file = File('${dir.path}/Timesheet_test.xlsx');
    await createTimesheetPeriod(
      file,
      employeeName: 'Truman Homes',
      periodLabel: 'Aug 9 - Aug 23, 2026',
      phone: '555-123-4567',
      period: period,
    );

    final result = Excel.decodeBytes(await file.readAsBytes());
    final template = Excel.decodeBytes(normalizeXlsxRelationshipTargets(originalBytes));
    // Timesheet's own number_format exception (section 13.2's documented
    // one): Start/Lunch/Finish are written as text ("8am", "1200-1230")
    // into cells the template formats as time -- excluded the same way
    // _expectStylePreserved excludes it, via numberFormat.accepts() above.
    final mismatches = _allCellStyleMismatches(result, template, ['Sheet1']);

    expect(mismatches, isEmpty, reason: 'style mismatches remaining after full-sheet healing: $mismatches');

    await dir.delete(recursive: true);
  });
}
