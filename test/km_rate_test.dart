// Section 6.2/7 (the $/km rate feature) and section 13 tests 10-11:
// - G1 is written at period creation from period.km_rate (or the Settings
//   default).
// - The rate-authority priority rule: G1 wins once filled; an empty G1
//   (old-template files) falls back to period.km_rate / Settings default
//   and self-heals by writing the result into G1.
// - Rates compare with tolerance, never `==`.
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/xlsx/cell_value_utils.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';

void main() {
  late List<int> originalBytes;
  late MileageReportEngine engine;
  late Sheet drivingSheet;
  late Sheet sheet;

  setUp(() {
    originalBytes = File(mileageTemplatePath).readAsBytesSync();
    engine = MileageReportEngine.fromBytes(originalBytes);
    sheet = engine.excel.sheets['Truman Homes']!;
    drivingSheet = engine.excel.sheets['Driving Details']!;
  });

  group('ratesEqual', () {
    test('treats a float round-trip tail as equal, not exact ==', () {
      expect(MileageReportEngine.ratesEqual(0.56, 0.5600000000000001), true);
    });

    test('flags a real difference as unequal', () {
      expect(MileageReportEngine.ratesEqual(0.56, 0.57), false);
    });
  });

  group('period creation (section 7, "Инициализация нового периода")', () {
    test('G1 is written from the period\'s own rate, and E8 starts at 0', () {
      engine.writeRate(0.72);
      engine.writePeriodHeader(periodLabel: 'x', employeeName: 'Truman Homes');
      engine.initializeKilometersRow(periodEnd: DateTime(2026, 8, 23));

      expect(numberOf(drivingSheet.cell(CellIndex.indexByString('G1')).value), 0.72);
      expect(numberOf(sheet.cell(CellIndex.indexByString('E8')).value), 0);
    });

    test('a period with a non-default rate computes Travel by that rate, not 0.56', () {
      engine.writeRate(0.72);
      engine.writePeriodHeader(periodLabel: 'x', employeeName: 'Truman Homes');
      engine.initializeKilometersRow(periodEnd: DateTime(2026, 8, 23));

      engine.writeDrivingDetail(date: DateTime(2026, 8, 10), trip: 'Site A', km: 100);

      expect(numberOf(sheet.cell(CellIndex.indexByString('E8')).value), 72.0);
    });
  });

  group('rate-authority priority rule (section 6.2)', () {
    setUp(() {
      engine.writePeriodHeader(periodLabel: 'x', employeeName: 'Truman Homes');
      engine.initializeKilometersRow(periodEnd: DateTime(2026, 8, 23));
    });

    test('an already-filled G1 is authoritative, even if a different periodKmRate is passed', () {
      // Template ships with G1 = 0.56 (case 2: file created, G1 filled).
      engine.writeDrivingDetail(
        date: DateTime(2026, 8, 10),
        trip: 'Site A',
        km: 100,
        periodKmRate: 0.99, // must be ignored -- G1 already has a value
        settingsDefaultRate: 0.99,
      );

      expect(numberOf(sheet.cell(CellIndex.indexByString('E8')).value), 56.0, reason: '100 * 0.56 (G1), not 0.99');
      expect(numberOf(drivingSheet.cell(CellIndex.indexByString('G1')).value), 0.56,
          reason: 'G1 must be untouched, not overwritten by periodKmRate/settingsDefaultRate');
    });

    test('an empty G1 (old-template file) falls back to periodKmRate and self-heals G1', () {
      // Simulate a file created before this feature existed (section 0,
      // "third case" of the priority rule): G1 empty/missing.
      drivingSheet.cell(CellIndex.indexByString('G1')).value = null;

      engine.writeDrivingDetail(
        date: DateTime(2026, 8, 10),
        trip: 'Site A',
        km: 100,
        periodKmRate: 0.65,
        settingsDefaultRate: 0.56,
      );

      expect(numberOf(sheet.cell(CellIndex.indexByString('E8')).value), 65.0,
          reason: 'should use periodKmRate (0.65), not the Settings default (0.56)');
      expect(numberOf(drivingSheet.cell(CellIndex.indexByString('G1')).value), 0.65,
          reason: 'G1 must be self-healed to the resolved rate so the file behaves like new from here on');
    });

    test('an empty G1 with no periodKmRate falls back to the Settings default', () {
      drivingSheet.cell(CellIndex.indexByString('G1')).value = null;

      engine.writeDrivingDetail(
        date: DateTime(2026, 8, 10),
        trip: 'Site A',
        km: 100,
        periodKmRate: null,
        settingsDefaultRate: 0.60,
      );

      expect(numberOf(sheet.cell(CellIndex.indexByString('E8')).value), 60.0);
      expect(numberOf(drivingSheet.cell(CellIndex.indexByString('G1')).value), 0.60);
    });

    test('resolveAndSyncRate on writeReceipt also self-heals an empty G1', () {
      drivingSheet.cell(CellIndex.indexByString('G1')).value = null;

      engine.writeReceipt(
        const ReceiptInput(subtotal: 10, gst: 0.5),
        currentKmTotal: 50,
        periodKmRate: 0.70,
        settingsDefaultRate: 0.56,
      );

      // The Kilometers row shifted to row 10 (first receipt).
      expect(numberOf(sheet.cell(CellIndex.indexByString('E10')).value), 35.0); // 50 * 0.70
      expect(numberOf(drivingSheet.cell(CellIndex.indexByString('G1')).value), 0.70);
    });
  });
}
