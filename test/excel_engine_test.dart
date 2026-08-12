// Section 13.4 priority test: exercises the excel-package-backed engines
// against the real templates with a batch of write operations, then checks
// structural integrity (hidden sheets untouched, formulas stay formulas,
// files open without error). Run with: `flutter test test/excel_engine_test.dart`
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/xlsx/cell_value_utils.dart';
import 'package:expenseflow/xlsx/excel_integrity.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';
import 'package:expenseflow/xlsx/timesheet_engine.dart';

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

    test('manually-entered Travel value on the Kilometers row survives later shifts', () {
      engine.writeReceipt(
        const ReceiptInput(date: null, description: null, subtotal: 45.99, gst: 2.30),
        currentKmTotal: 0,
      );
      // Kilometers row is now at 10; simulate the user filling Travel by hand.
      sheet.cell(CellIndex.indexByString('E10')).value = const DoubleCellValue(12.0);

      engine.writeReceipt(
        const ReceiptInput(date: null, description: null, subtotal: 12.00, gst: 0.60),
        currentKmTotal: 0,
      );

      expect(engine.findKilometersRow(), 11);
      expect(numberOf(sheet.cell(CellIndex.indexByString('E11')).value), 12.0);
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

      final report = checkMileageReportIntegrity(originalBytes: originalBytes, newBytes: newBytes);
      expect(report.ok, true, reason: report.issues.join('; '));

      final reopened = MileageReportEngine.fromBytes(outFile.readAsBytesSync());
      expect(reopened.findKilometersRow(), engine.findKilometersRow());
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

      final report = checkTimesheetIntegrity(newBytes: newBytes);
      expect(report.ok, true, reason: report.issues.join('; '));
    });
  });
}
