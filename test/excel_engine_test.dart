// Section 13.4 priority test: exercises the excel-package-backed engines
// against the real templates with a batch of write operations, then checks
// structural integrity (hidden sheets untouched, formulas stay formulas,
// files open without error). Run with: `flutter test test/excel_engine_test.dart`
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/xlsx/cell_value_utils.dart';
import 'package:expenseflow/xlsx/excel_integrity.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';
import 'package:expenseflow/xlsx/timesheet_engine.dart';
import 'package:expenseflow/xlsx/xlsx_rels_compat.dart';

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';
const timesheetTemplatePath = 'assets/templates/Truman_Homes_Timesheet_TEMPLATE.xlsx';

void main() {
  group('MileageReportEngine', () {
    late List<int> originalBytes;
    late MileageReportEngine engine;
    late Sheet sheet;

    setUp(() {
      originalBytes = File(mileageTemplatePath).readAsBytesSync();
      engine = MileageReportEngine.fromBytes(originalBytes);
      sheet = engine.excel.sheets['Truman Homes']!;

      engine.writePeriodHeader(periodLabel: 'Aug 9 - Aug 23, 2026', employeeName: 'Truman Homes');
      engine.initializeKilometersRow(periodEnd: DateTime(2026, 8, 23));
    });

    test('initializes the Kilometers row at 8 with no receipts', () {
      expect(engine.findKilometersRow(), 8);
      expect(textOf(sheet.cell(CellIndex.indexByString('B8')).value), 'Kilometers (0)');
    });

    test('Driving Details entries update the Kilometers row before any receipt exists', () {
      engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A to Site B', km: 42.5);
      engine.writeDrivingDetail(date: DateTime(2026, 8, 12), trip: 'Site B to warehouse', km: 15);

      expect(engine.sumDrivingDetailsKm(), 57.5);
      expect(textOf(sheet.cell(CellIndex.indexByString('B8')).value), 'Kilometers (57.5)');
    });

    test('first receipt shifts the Kilometers row 8 -> 10 and leaves row 9 as the gap', () {
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

      expect(engine.findKilometersRow(), 10);
      expect(textOf(sheet.cell(CellIndex.indexByString('B10')).value), 'Kilometers (42.5)');
      expect(numberOf(sheet.cell(CellIndex.indexByString('D8')).value), 45.99);
      expect(numberOf(sheet.cell(CellIndex.indexByString('K8')).value), 2.30);
      expect(isEmptyCell(sheet.cell(CellIndex.indexByString('B9')).value), true);
      expect(isEmptyCell(sheet.cell(CellIndex.indexByString('A9')).value), true);
    });

    // Section 7: Travel on the Kilometers row is ALWAYS recomputed as
    // round(N x rate, 2) as the row shifts -- never just carried over. The
    // template ships with G1 = 0.56, so a stray/manually-set E value must
    // be overwritten by that computation on the very next shift, not
    // preserved.
    test('Travel on the Kilometers row is recomputed (not carried over) as it shifts', () {
      engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A', km: 100);
      engine.writeReceipt(
        const ReceiptInput(date: null, description: null, subtotal: 45.99, gst: 2.30),
        currentKmTotal: 100,
      );
      // Kilometers row is now at 10, Travel should be 100 * 0.56 = 56.
      expect(numberOf(sheet.cell(CellIndex.indexByString('E10')).value), 56.0);

      // Simulate a stray/manually-set value landing on the Kilometers row's
      // Travel cell -- the next shift must overwrite it, not preserve it.
      sheet.cell(CellIndex.indexByString('E10')).value = const DoubleCellValue(999.0);

      engine.writeReceipt(
        const ReceiptInput(date: null, description: null, subtotal: 12.00, gst: 0.60),
        currentKmTotal: 100,
      );

      expect(engine.findKilometersRow(), 11);
      expect(numberOf(sheet.cell(CellIndex.indexByString('E11')).value), 56.0,
          reason: 'Travel must be recomputed from KM total x rate, not carried over from the stray E10 value');
      expect(numberOf(sheet.cell(CellIndex.indexByString('D9')).value), 12.00);
      expect(isEmptyCell(sheet.cell(CellIndex.indexByString('B10')).value), true);
    });

    test('rejects writes past capacity without any partial mutation', () {
      // rows 8-27 = 20 rows; kilometers row + gap consume 2, so 18 receipts fit.
      for (var i = 0; i < 18; i++) {
        engine.writeReceipt(
          ReceiptInput(date: DateTime(2026, 8, 10 + i % 10), subtotal: 10.0 + i, gst: 0.5 + i * 0.05),
          currentKmTotal: 0,
        );
      }
      expect(engine.findKilometersRow(), 27);

      expect(
        () => engine.writeReceipt(
          const ReceiptInput(date: null, subtotal: 99, gst: 4.95),
          currentKmTotal: 0,
        ),
        throwsA(isA<MileageReportRowsExhaustedException>()),
      );
      expect(engine.findKilometersRow(), 27, reason: 'no row should have moved on the rejected write');
      expect(isEmptyCell(sheet.cell(CellIndex.indexByString('D27')).value), true,
          reason: 'the rejected receipt must not have been written anywhere');
    });

    // Section 13.13: the write algorithm assumes the row(s) it's about to
    // move into are empty (it's the only writer of the working file --
    // section 1a). These fixtures force that assumption to fail, simulating
    // an interrupted prior write or an algorithm bug, not a user edit.
    group('occupied gap row', () {
      test('first receipt (km row at 8): occupied row 9 blocks the write, nothing moves', () {
        sheet.cell(CellIndex.indexByString('D9')).value = const DoubleCellValue(1);

        expect(
          () => engine.writeReceipt(const ReceiptInput(subtotal: 10, gst: 0.5), currentKmTotal: 0),
          throwsA(isA<MileageReportRowOccupiedException>()),
        );
        expect(engine.findKilometersRow(), 8, reason: 'km row must not have moved');
        expect(textOf(sheet.cell(CellIndex.indexByString('B8')).value), 'Kilometers (0)');
      });

      test('first receipt (km row at 8): occupied row 10 blocks the write, nothing moves', () {
        sheet.cell(CellIndex.indexByString('K10')).value = const DoubleCellValue(1);

        expect(
          () => engine.writeReceipt(const ReceiptInput(subtotal: 10, gst: 0.5), currentKmTotal: 0),
          throwsA(isA<MileageReportRowOccupiedException>()),
        );
        expect(engine.findKilometersRow(), 8, reason: 'km row must not have moved');
      });

      test('subsequent receipt: occupied gap row blocks the write, nothing moves', () {
        engine.writeReceipt(const ReceiptInput(subtotal: 10, gst: 0.5), currentKmTotal: 0);
        expect(engine.findKilometersRow(), 10);
        // Row 9 is now the gap; corrupt it before the next write.
        sheet.cell(CellIndex.indexByString('A9')).value = TextCellValue('unexpected');

        expect(
          () => engine.writeReceipt(const ReceiptInput(subtotal: 20, gst: 1), currentKmTotal: 0),
          throwsA(isA<MileageReportRowOccupiedException>()),
        );
        expect(engine.findKilometersRow(), 10, reason: 'km row must not have moved on the rejected write');
        expect(numberOf(sheet.cell(CellIndex.indexByString('D9')).value), isNot(20),
            reason: 'the rejected receipt must not have been written into the occupied gap row');
      });
    });

    test('more than one "Kilometers (" row is a blocking structure error, not a silent pick', () {
      // Simulate corruption: a second row that also looks like the
      // Kilometers marker (section 13.1a) -- this should never happen
      // through normal app use (the app is the only writer, section 1a).
      sheet.cell(CellIndex.indexByString('B15')).value = TextCellValue('Kilometers (999)');

      expect(
        () => engine.findKilometersRow(),
        throwsA(isA<MileageReportStructureException>()),
      );
      expect(
        () => engine.writeReceipt(const ReceiptInput(subtotal: 10, gst: 0.5), currentKmTotal: 0),
        throwsA(isA<MileageReportStructureException>()),
      );
    });

    // Section 13.17: a value with a long decimal tail must land in the file
    // rounded to 2 places -- otherwise the cell's #,##0.00 display and the
    // stored value silently disagree.
    test('a long decimal tail on Subtotal/GST/KM is rounded to 2 places before it reaches the file', () {
      engine.writeReceipt(
        const ReceiptInput(subtotal: 12.3456, gst: 0.6789),
        currentKmTotal: 0,
      );
      expect(numberOf(sheet.cell(CellIndex.indexByString('D8')).value), 12.35);
      expect(numberOf(sheet.cell(CellIndex.indexByString('K8')).value), 0.68);

      engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A', km: 42.5678);
      final drivingSheet = engine.excel.sheets['Driving Details']!;
      expect(numberOf(drivingSheet.cell(CellIndex.indexByString('C2')).value), 42.57);
    });

    // Section 8: any human-typed text (Description, Trip, employee name,
    // STAT holiday name, ...) must be stored as literal text even if it
    // starts with =, +, -, or @ -- those are the characters Excel treats as
    // "this cell is a formula" on values typed directly into the grid. The
    // app never types into the grid; it always goes through TextCellValue,
    // which tags the cell's type explicitly rather than sniffing the first
    // character, so this must hold regardless of content.
    test('a Description starting with "=" is stored as text, not turned into a formula', () {
      engine.writeReceipt(
        const ReceiptInput(description: '=SUM(A1:A2)', subtotal: 10, gst: 0.5),
        currentKmTotal: 0,
      );

      final roundTripped = MileageReportEngine.fromBytes(engine.save()).excel.sheets['Truman Homes']!;
      final value = roundTripped.cell(CellIndex.indexByString('B8')).value;
      expect(value, isA<TextCellValue>());
      expect(textOf(value), '=SUM(A1:A2)');
    });

    test('receipt and driving-detail cells keep the template border/font/number_format after being written', () {
      final templateSheet = MileageReportEngine.fromBytes(originalBytes).excel.sheets['Truman Homes']!;
      final templateDrivingSheet = MileageReportEngine.fromBytes(originalBytes).excel.sheets['Driving Details']!;

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

      for (final a1 in ['A8', 'B8', 'D8', 'K8', 'A10', 'B10']) {
        final written = sheet.cell(CellIndex.indexByString(a1)).cellStyle;
        final template = templateSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        expect(written, isNotNull, reason: '$a1 should still have a style after being written');
        expect(written!.numberFormat.formatCode, template!.numberFormat.formatCode,
            reason: '$a1 number_format should match the template');
        expect(written.fontFamily, template.fontFamily, reason: '$a1 font family should match the template');
        expect(written.fontSize, template.fontSize, reason: '$a1 font size should match the template');
        expect(written.topBorder, template.topBorder, reason: '$a1 top border should match the template');
        expect(written.bottomBorder, template.bottomBorder, reason: '$a1 bottom border should match the template');
      }

      final drivingSheet = engine.excel.sheets['Driving Details']!;
      for (final a1 in ['A2', 'B2', 'C2']) {
        final written = drivingSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        final template = templateDrivingSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        expect(written, isNotNull, reason: '$a1 should still have a style after being written');
        expect(written!.numberFormat.formatCode, template!.numberFormat.formatCode,
            reason: '$a1 number_format should match the template');
        expect(written.fontFamily, template.fontFamily, reason: '$a1 font family should match the template');
      }
    });

    test('written file passes the integrity check and survives a disk round-trip', () {
      engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A to Site B', km: 42.5);
      for (var i = 0; i < 5; i++) {
        engine.writeReceipt(
          ReceiptInput(date: DateTime(2026, 8, 10 + i), subtotal: 10.0 + i, gst: 0.5 + i * 0.05),
          currentKmTotal: engine.sumDrivingDetailsKm(),
        );
      }

      final newBytes = engine.save();
      final outFile = File('build/verify_output/MileageReport_test.xlsx')..createSync(recursive: true);
      outFile.writeAsBytesSync(newBytes);

      final report = checkMileageReportIntegrity(
          newBytes: newBytes,
          template: Excel.decodeBytes(normalizeXlsxRelationshipTargets(Uint8List.fromList(originalBytes))));
      expect(report.ok, true, reason: report.issues.join('; '));
      expect(report.styleWarnings, isEmpty, reason: report.styleWarnings.join('; '));

      final reopened = MileageReportEngine.fromBytes(outFile.readAsBytesSync());
      expect(reopened.findKilometersRow(), engine.findKilometersRow());
    });

    group('listReceipts / listDrivingDetails (section 14)', () {
      test('listReceipts excludes the Kilometers row and empty rows', () {
        engine.writeReceipt(
          ReceiptInput(date: DateTime(2026, 8, 10), description: 'Home Depot', subtotal: 45.99, gst: 2.30),
          currentKmTotal: 0,
        );
        engine.writeReceipt(
          ReceiptInput(date: DateTime(2026, 8, 11), subtotal: 12.5, gst: 0.63),
          currentKmTotal: 0,
        );

        final receipts = engine.listReceipts();
        expect(receipts.length, 2, reason: 'must exclude the Kilometers row -- 3 receipt rows are non-empty total');
        expect(receipts.any((r) => r.description?.startsWith('Kilometers (') ?? false), isFalse);
        expect(receipts.map((r) => r.description), containsAll(['Home Depot', null]));
        expect(receipts.map((r) => r.subtotal), containsAll([45.99, 12.5]));
      });

      test('listDrivingDetails only includes rows with content', () {
        engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A to Site B', km: 42.5);
        engine.writeDrivingDetail(date: DateTime(2026, 8, 12), trip: 'Site C', km: 10);

        final trips = engine.listDrivingDetails();
        expect(trips.length, 2);
        expect(trips.map((t) => t.trip), ['Site A to Site B', 'Site C']);
        expect(trips.map((t) => t.km), [42.5, 10.0]);
      });
    });

    group('updateReceipt / updateDrivingDetail (section 14 -- edit in place, no shift)', () {
      test('updateReceipt overwrites the given row without moving the Kilometers row', () {
        engine.writeReceipt(
          ReceiptInput(date: DateTime(2026, 8, 10), description: 'Home Depot', subtotal: 45.99, gst: 2.30),
          currentKmTotal: 0,
        );
        final receipt = engine.listReceipts().single;
        final kmRowBefore = engine.findKilometersRow();

        engine.updateReceipt(
          receipt.row,
          const ReceiptInput(date: null, description: 'Corrected description', subtotal: 50.0, gst: 2.5),
        );

        expect(engine.findKilometersRow(), kmRowBefore, reason: 'editing an existing row must not shift Kilometers');
        final updated = engine.listReceipts().single;
        expect(updated.row, receipt.row);
        expect(updated.description, 'Corrected description');
        expect(updated.subtotal, 50.0);
        expect(updated.gst, 2.5);
      });

      test('updateReceipt clears Description when passed empty -- unlike the add path, edit must clear', () {
        engine.writeReceipt(
          ReceiptInput(date: DateTime(2026, 8, 10), description: 'Home Depot', subtotal: 45.99, gst: 2.30),
          currentKmTotal: 0,
        );
        final receipt = engine.listReceipts().single;

        engine.updateReceipt(receipt.row, ReceiptInput(date: receipt.date, description: '', subtotal: receipt.subtotal, gst: receipt.gst));

        expect(engine.listReceipts().single.description, isNull);
      });

      test('updateReceipt refuses to overwrite the Kilometers row', () {
        expect(
          () => engine.updateReceipt(engine.findKilometersRow()!, const ReceiptInput(subtotal: 1)),
          throwsArgumentError,
        );
      });

      test('updateDrivingDetail overwrites the given row and recalculates the Kilometers row', () {
        engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A to Site B', km: 42.5);
        engine.writeDrivingDetail(date: DateTime(2026, 8, 12), trip: 'Site C', km: 10);
        final target = engine.listDrivingDetails().first;

        engine.updateDrivingDetail(target.row, date: DateTime(2026, 8, 10), trip: 'Site A to Site B (corrected)', km: 100);

        final trips = engine.listDrivingDetails();
        expect(trips.length, 2, reason: 'editing must not add or remove rows');
        expect(trips.first.trip, 'Site A to Site B (corrected)');
        expect(trips.first.km, 100.0);
        expect(engine.sumDrivingDetailsKm(), 110.0); // 100 + 10, KM total recalculated
        expect(textOf(sheet.cell(CellIndex.indexByString('B${engine.findKilometersRow()}')).value),
            'Kilometers (110)');
      });
    });
  });

  group('TimesheetEngine', () {
    late List<int> originalBytes;
    late TimesheetEngine engine;
    late Sheet sheet;
    late PayrollPeriod period;

    setUp(() {
      originalBytes = File(timesheetTemplatePath).readAsBytesSync();
      engine = TimesheetEngine.fromBytes(originalBytes);
      sheet = engine.excel.sheets['Sheet1']!;
      period = PayrollPeriod(
        key: '2026-08-09_2026-08-23',
        start: DateTime(2026, 8, 9),
        end: DateTime(2026, 8, 23),
        due: DateTime(2026, 8, 21, 16, 30),
        weekendAltDue: DateTime(2026, 8, 23, 8, 30),
        statHolidays: const [],
      );
      engine.writeHeader(employeeName: 'Truman Homes', periodLabel: 'Aug 9 - Aug 23, 2026', phone: '555-123-4567');
      engine.autoFillPeriod(period);
    });

    test('auto-fill leaves weekends blank and fills weekdays with defaults', () {
      // 2026-08-09 is a Sunday.
      expect(isEmptyCell(sheet.cell(CellIndex.indexByString('C8')).value), true);
      // 2026-08-10 is a Monday.
      expect(textOf(sheet.cell(CellIndex.indexByString('C9')).value), '8am');
      expect(textOf(sheet.cell(CellIndex.indexByString('D9')).value), '1200-1230');
      expect(textOf(sheet.cell(CellIndex.indexByString('F9')).value), '430pm');
      expect(numberOf(sheet.cell(CellIndex.indexByString('G9')).value), 8);
      expect(numberOf(sheet.cell(CellIndex.indexByString('H9')).value), 8);
    });

    test('auto-fill respects a STAT holiday inside the period', () {
      final statPeriod = period.copyWith(statHolidays: [StatHoliday(name: 'Heritage Day', date: DateTime(2026, 8, 10))]);
      final freshEngine = TimesheetEngine.fromBytes(File(timesheetTemplatePath).readAsBytesSync());
      freshEngine.writeHeader(employeeName: 'Truman Homes', periodLabel: 'x', phone: '555');
      freshEngine.autoFillPeriod(statPeriod);
      final freshSheet = freshEngine.excel.sheets['Sheet1']!;
      // 2026-08-10 (row 9) is the STAT day -> should stay blank despite being a weekday.
      expect(isEmptyCell(freshSheet.cell(CellIndex.indexByString('C9')).value), true);
    });

    test('rows past the period length stay blank', () {
      final totalDays = period.end.difference(period.start).inDays + 1;
      expect(totalDays, 15);
      final lastFilledRow = TimesheetEngine.firstDayRow + totalDays - 1;
      expect(isEmptyCell(sheet.cell(CellIndex.indexByString('B${lastFilledRow + 1}')).value), true);
    });

    test('editing a day formats times and recomputes Hours/H39', () {
      engine.writeDay(
        9,
        const TimesheetDayInput(
          start: TimeOfDay(hour: 8, minute: 0),
          lunchStart: TimeOfDay(hour: 12, minute: 0),
          lunchEnd: TimeOfDay(hour: 12, minute: 30),
          finish: TimeOfDay(hour: 16, minute: 45),
        ),
      );

      expect(textOf(sheet.cell(CellIndex.indexByString('F9')).value), '445pm');
      expect(numberOf(sheet.cell(CellIndex.indexByString('G9')).value), 8.25);
      expect(numberOf(sheet.cell(CellIndex.indexByString('H9')).value), 8.25);

      double expectedTotal = 0;
      for (var row = TimesheetEngine.firstDayRow; row <= TimesheetEngine.lastDayRow; row++) {
        expectedTotal += numberOf(sheet.cell(CellIndex.indexByColumnRow(columnIndex: 7, rowIndex: row - 1)).value) ?? 0;
      }
      expect(numberOf(sheet.cell(CellIndex.indexByString('H39')).value), expectedTotal);
    });

    test('clearing a day blanks C-H and recomputes H39, leaving Item#/Date alone', () {
      engine.writeDay(
        9,
        const TimesheetDayInput(
          start: TimeOfDay(hour: 8, minute: 0),
          lunchStart: TimeOfDay(hour: 12, minute: 0),
          lunchEnd: TimeOfDay(hour: 12, minute: 30),
          finish: TimeOfDay(hour: 16, minute: 45),
        ),
      );
      final totalBeforeClear = numberOf(sheet.cell(CellIndex.indexByString('H39')).value)!;

      engine.clearDay(9);

      for (final col in ['C', 'D', 'E', 'F', 'G', 'H']) {
        expect(isEmptyCell(sheet.cell(CellIndex.indexByString('${col}9')).value), true, reason: '${col}9 should be blank');
      }
      // Item# and Date are section 10's "not the app's to clear" columns.
      expect(numberOf(sheet.cell(CellIndex.indexByString('A9')).value), 2);
      expect(sheet.cell(CellIndex.indexByString('B9')).value, isNotNull);
      expect(numberOf(sheet.cell(CellIndex.indexByString('H39')).value), totalBeforeClear - 8.25);
    });

    test('written day and header cells keep the template border/font/number_format', () {
      final templateSheet = TimesheetEngine.fromBytes(originalBytes).excel.sheets['Sheet1']!;

      engine.writeDay(
        9,
        const TimesheetDayInput(
          start: TimeOfDay(hour: 8, minute: 0),
          lunchStart: TimeOfDay(hour: 12, minute: 0),
          lunchEnd: TimeOfDay(hour: 12, minute: 30),
          finish: TimeOfDay(hour: 16, minute: 45),
        ),
      );

      for (final a1 in ['B9', 'C9', 'D9', 'F9', 'G9', 'H9', 'H39']) {
        final written = sheet.cell(CellIndex.indexByString(a1)).cellStyle;
        final template = templateSheet.cell(CellIndex.indexByString(a1)).cellStyle;
        expect(written, isNotNull, reason: '$a1 should still have a style after being written');
        expect(written!.numberFormat.formatCode, template!.numberFormat.formatCode,
            reason: '$a1 number_format should match the template');
        expect(written.fontFamily, template.fontFamily, reason: '$a1 font family should match the template');
        expect(written.fontSize, template.fontSize, reason: '$a1 font size should match the template');
        expect(written.topBorder, template.topBorder, reason: '$a1 top border should match the template');
        expect(written.bottomBorder, template.bottomBorder, reason: '$a1 bottom border should match the template');
      }
    });

    test('written file passes the integrity check', () {
      engine.writeDay(
        9,
        const TimesheetDayInput(
          start: TimeOfDay(hour: 8, minute: 0),
          lunchStart: TimeOfDay(hour: 12, minute: 0),
          lunchEnd: TimeOfDay(hour: 12, minute: 30),
          finish: TimeOfDay(hour: 16, minute: 45),
        ),
      );
      final newBytes = engine.save();
      final outFile = File('build/verify_output/Timesheet_test.xlsx')..createSync(recursive: true);
      outFile.writeAsBytesSync(newBytes);

      final report = checkTimesheetIntegrity(newBytes: newBytes, template: Excel.decodeBytes(originalBytes));
      expect(report.ok, true, reason: report.issues.join('; '));
      expect(report.styleWarnings, isEmpty, reason: report.styleWarnings.join('; '));
    });
  });
}
