// Section 14 (view/edit already-saved receipts and trips), pipeline level:
// updateMileageReceipt/updateMileageDrivingDetail go through the same
// isolate/heal/patch/verify conveyor as every other write (safe_xlsx_write.
// dart), just via a different engine call (update-in-place vs the
// Kilometers-row-shift/free-row-search add path). This is the level the
// screens actually call at -- confirms the full real conveyor keeps
// integrity clean for the edit path, not just the bare engine.
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/xlsx/excel_integrity.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';
import 'package:expenseflow/xlsx/xlsx_rels_compat.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory dir;
  late File file;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('receipt_edit_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(dir.path);
    file = File('${dir.path}/MileageReport_test.xlsx');
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
  });

  tearDown(() async {
    await dir.delete(recursive: true);
  });

  test('updateMileageReceipt edits the existing row in place and passes the full integrity check', () async {
    final before = await readMileageReportSummary(file);
    final receipt = before.receipts.single;
    final kmRowBefore = before.drivingDetails.single.row;

    await updateMileageReceipt(
      file,
      row: receipt.row,
      receipt: const ReceiptInput(date: null, description: 'Corrected description', subtotal: 50.0, gst: 2.5),
    );

    final after = await readMileageReportSummary(file);
    expect(after.receipts.single.row, receipt.row, reason: 'edit must not move the row');
    expect(after.receipts.single.description, 'Corrected description');
    expect(after.receipts.single.subtotal, 50.0);
    expect(after.drivingDetails.single.row, kmRowBefore, reason: 'unrelated Driving Details row must be untouched');

    final bytes = await file.readAsBytes();
    final template = Excel.decodeBytes(
        normalizeXlsxRelationshipTargets(File(mileageTemplatePath).readAsBytesSync()));
    final report = checkMileageReportIntegrity(newBytes: bytes, template: template);
    expect(report.ok, isTrue, reason: report.issues.join('; '));
    expect(report.styleWarnings, isEmpty, reason: report.styleWarnings.join('; '));
  });

  test('updateMileageDrivingDetail edits the existing row and recalculates the Kilometers row', () async {
    final before = await readMileageReportSummary(file);
    final trip = before.drivingDetails.single;

    await updateMileageDrivingDetail(
      file,
      row: trip.row,
      date: DateTime(2026, 8, 11),
      trip: 'Corrected trip',
      km: 100,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );

    final after = await readMileageReportSummary(file);
    expect(after.drivingDetails.single.row, trip.row, reason: 'edit must not move the row');
    expect(after.drivingDetails.single.trip, 'Corrected trip');
    expect(after.drivingDetails.single.km, 100.0);
    expect(after.receipts.single.row, before.receipts.single.row, reason: 'unrelated receipt row must be untouched');

    final bytes = await file.readAsBytes();
    final excel = Excel.decodeBytes(bytes);
    final kmRow = MileageReportEngine(excel).findKilometersRow()!;
    expect(excel.sheets['Truman Homes']!.cell(CellIndex.indexByString('B$kmRow')).value.toString(),
        contains('Kilometers (100)'));

    final template = Excel.decodeBytes(
        normalizeXlsxRelationshipTargets(File(mileageTemplatePath).readAsBytesSync()));
    final report = checkMileageReportIntegrity(newBytes: bytes, template: template);
    expect(report.ok, isTrue, reason: report.issues.join('; '));
    expect(report.styleWarnings, isEmpty, reason: report.styleWarnings.join('; '));
  });

  test('readMileageReportSummary lists the seeded receipt and trip', () async {
    final summary = await readMileageReportSummary(file);
    expect(summary.receipts, hasLength(1));
    expect(summary.drivingDetails, hasLength(1));
    expect(summary.receipts.single.description, 'Home Depot - toilet fill valve, garbage bags');
    expect(summary.drivingDetails.single.trip, 'Site A to Site B');
  });
}
