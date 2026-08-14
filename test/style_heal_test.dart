// Regression test for the real-device finding: a period file that was
// already written to by a pre-fix build of the app has its managed cells'
// border/font/number_format wiped to the `excel` package's default (see
// setCellValue in lib/xlsx/cell_value_utils.dart for why). Once the
// style-integrity check in excel_integrity.dart existed, writing to such an
// already-damaged file started throwing XlsxIntegrityException on every
// save, because cells the write didn't touch were still out of sync with
// the template. writeMileageReportSafely/writeTimesheetSafely now heal the
// whole managed range against the pristine template before checking, so a
// write to an already-damaged file (a) does not throw and (b) leaves
// previously-damaged, untouched cells repaired too.
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';
import 'package:expenseflow/xlsx/timesheet_engine.dart';

/// writeMileageReportSafely/writeTimesheetSafely back up the file via
/// BackupManager, which resolves its directory through path_provider (a
/// platform channel with no implementation under `flutter test`). Point it
/// at a throwaway temp dir instead of mocking the channel by hand.
class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';
const timesheetTemplatePath = 'assets/templates/Truman_Homes_Timesheet_TEMPLATE.xlsx';

/// Reproduces exactly what a pre-fix build did: `Data.value =` on the
/// `excel` package always resets the cell's style to a bare default as a
/// side effect (see Sheet._putData in the excel package), regardless of
/// whether the value actually changes. Reassigning through the raw setter
/// (bypassing setCellValue) recreates that damage faithfully.
void _corruptStyleInPlace(Sheet sheet, String a1) {
  final cell = sheet.cell(CellIndex.indexByString(a1));
  cell.value = cell.value;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final docsDir = await Directory.systemTemp.createTemp('style_heal_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  group('style healing', () {
    test('a Timesheet file already damaged by a pre-fix write is healed instead of blocking future saves', () async {
      final originalBytes = File(timesheetTemplatePath).readAsBytesSync();
      final period = PayrollPeriod(
        key: '2026-08-09_2026-08-23',
        start: DateTime(2026, 8, 9),
        end: DateTime(2026, 8, 23),
        due: DateTime(2026, 8, 21, 16, 30),
        weekendAltDue: DateTime(2026, 8, 23, 8, 30),
        statHolidays: const [],
      );

      final engine = TimesheetEngine.fromBytes(originalBytes);
      engine.writeHeader(employeeName: 'Truman Homes', periodLabel: 'Aug 9 - Aug 23, 2026', phone: '555-123-4567');
      engine.autoFillPeriod(period);

      // Simulate pre-existing damage on cells this test will NOT touch again.
      final damagedSheet = engine.excel.sheets['Sheet1']!;
      const damagedCells = ['C9', 'D9', 'F9', 'C10', 'D10', 'F10'];
      for (final a1 in damagedCells) {
        _corruptStyleInPlace(damagedSheet, a1);
      }

      final dir = await Directory.systemTemp.createTemp('style_heal_timesheet_test');
      final file = File('${dir.path}/Timesheet_test.xlsx');
      await file.writeAsBytes(engine.save());

      // Sanity check: the fixture really is damaged before healing. Border
      // is the reliable signal here -- a wiped-to-default style has no
      // border at all, whereas font family can coincidentally match the
      // workbook's overall default font even on a wiped cell.
      final templateSheet = TimesheetEngine.fromBytes(originalBytes).excel.sheets['Sheet1']!;
      final beforeSheet = TimesheetEngine.fromBytes(await file.readAsBytes()).excel.sheets['Sheet1']!;
      for (final a1 in damagedCells) {
        expect(
          beforeSheet.cell(CellIndex.indexByString(a1)).cellStyle?.topBorder,
          isNot(templateSheet.cell(CellIndex.indexByString(a1)).cellStyle?.topBorder),
          reason: '$a1 should be a damaged fixture before healing',
        );
      }

      // Edit an unrelated day (row 11 = 2026-08-12). This must not throw
      // despite the pre-existing damage elsewhere in the file.
      await saveTimesheetDay(
        file,
        row: 11,
        input: const TimesheetDayInput(
          start: TimeOfDay(hour: 8, minute: 0),
          lunchStart: TimeOfDay(hour: 12, minute: 0),
          lunchEnd: TimeOfDay(hour: 12, minute: 30),
          finish: TimeOfDay(hour: 16, minute: 45),
        ),
      );

      // The previously-damaged, untouched-by-this-write cells should now be
      // healed to match the template too.
      final afterSheet = TimesheetEngine.fromBytes(await file.readAsBytes()).excel.sheets['Sheet1']!;
      for (final a1 in damagedCells) {
        final healed = afterSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        final template = templateSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        expect(healed?.fontFamily, template?.fontFamily, reason: '$a1 font family should be healed');
        expect(healed?.fontSize, template?.fontSize, reason: '$a1 font size should be healed');
        expect(healed?.topBorder, template?.topBorder, reason: '$a1 top border should be healed');
        expect(healed?.bottomBorder, template?.bottomBorder, reason: '$a1 bottom border should be healed');
      }

      await dir.delete(recursive: true);
    });

    test(
        'a Mileage Report file already damaged by a pre-fix write is healed instead of blocking future saves',
        () async {
      final originalBytes = File(mileageTemplatePath).readAsBytesSync();

      final engine = MileageReportEngine.fromBytes(originalBytes);
      engine.writePeriodHeader(periodLabel: 'Aug 9 - Aug 23, 2026', employeeName: 'Truman Homes');
      engine.initializeKilometersRow(periodEnd: DateTime(2026, 8, 23));
      engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A to Site B', km: 42.5);
      engine.writeReceipt(
        ReceiptInput(
          date: DateTime(2026, 8, 10),
          description: 'Home Depot - toilet fill valve, garbage bags',
          subtotal: 45.99,
          gst: 2.30,
        ),
        currentKmTotal: engine.sumDrivingDetailsKm(),
      );

      // Simulate pre-existing damage on cells this test will NOT touch again.
      final damagedSheet = engine.excel.sheets['Truman Homes']!;
      const damagedCells = ['A8', 'D8', 'K8'];
      for (final a1 in damagedCells) {
        _corruptStyleInPlace(damagedSheet, a1);
      }

      final dir = await Directory.systemTemp.createTemp('style_heal_mileage_test');
      final file = File('${dir.path}/MileageReport_test.xlsx');
      await file.writeAsBytes(engine.save());

      // bottomBorder is the reliable signal here (these cells have no
      // topBorder even in the pristine template).
      final templateSheet = MileageReportEngine.fromBytes(originalBytes).excel.sheets['Truman Homes']!;
      final beforeSheet = MileageReportEngine.fromBytes(await file.readAsBytes()).excel.sheets['Truman Homes']!;
      for (final a1 in damagedCells) {
        expect(
          beforeSheet.cell(CellIndex.indexByString(a1)).cellStyle?.bottomBorder,
          isNot(templateSheet.cell(CellIndex.indexByString(a1)).cellStyle?.bottomBorder),
          reason: '$a1 should be a damaged fixture before healing',
        );
      }

      // Add a new receipt (unrelated to the already-damaged row 8 cells,
      // which get pushed down but never rewritten by this action since the
      // Kilometers row shift only touches A/B/E, not D/K).
      await saveMileageReceipt(
        file,
        const ReceiptInput(date: null, description: null, subtotal: 12.5, gst: 0.63),
      );

      final afterSheet = MileageReportEngine.fromBytes(await file.readAsBytes()).excel.sheets['Truman Homes']!;
      for (final a1 in damagedCells) {
        final healed = afterSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        final template = templateSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        expect(healed?.fontFamily, template?.fontFamily, reason: '$a1 font family should be healed');
        expect(healed?.topBorder, template?.topBorder, reason: '$a1 top border should be healed');
        expect(healed?.bottomBorder, template?.bottomBorder, reason: '$a1 bottom border should be healed');
      }

      await dir.delete(recursive: true);
    });
  });
}
