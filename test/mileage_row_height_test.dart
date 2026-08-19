// Пакет 25 (Вариант A, audit 2026-08-18): rows 8-27 (Truman Homes,
// Description) and 2-18 (Driving Details, Trip) must not carry an explicit
// `ht`/`customHeight` after any real write -- wrapText is already enabled
// on both columns, so real Excel's own auto-fit is what decides their
// height, whether the row is empty, holds a short one-line entry, or a
// long wrapped Description. This is the one thing an automated test CAN
// verify (that our own code stops forcing a height) -- the actual rendered
// height in real Excel needs a live-device check, see
// [[expenseflow-device-testing]].
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:xml/xml.dart';

import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

XmlDocument _sheetXml(List<int> xlsxBytes, String sheetPath) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  return XmlDocument.parse(utf8.decode(archive.findFile(sheetPath)!.content as List<int>));
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final docsDir = await Directory.systemTemp.createTemp('row_height_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  test('rows 8-27 (Truman Homes) and 2-18 (Driving Details) never carry an explicit height after real writes',
      () async {
    final dir = await Directory.systemTemp.createTemp('row_height_test');
    final file = File('${dir.path}/MileageReport_test.xlsx');

    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );
    // A long Description that would wrap to several lines in real Excel --
    // exactly the case a forced fixed height used to handle by being tall
    // enough for the worst case, wasting space on every other row.
    await saveMileageReceipt(
      file,
      const ReceiptInput(
        date: null,
        description: 'Home Depot - fill valve set, weatherstrip, key duplicates, extra long note for wrapping',
        subtotal: 45.99,
        gst: 2.30,
      ),
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );
    await saveMileageDrivingDetail(
      file,
      date: DateTime(2026, 8, 10),
      trip: 'Site A to Site B',
      km: 42.5,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );

    final bytes = await file.readAsBytes();
    final trumanHomes = _sheetXml(bytes, 'xl/worksheets/sheet2.xml');
    final drivingDetails = _sheetXml(bytes, 'xl/worksheets/sheet3.xml');

    final trumanHomesRows = {
      for (final row in trumanHomes.findAllElements('row'))
        if (int.tryParse(row.getAttribute('r') ?? '') != null) int.parse(row.getAttribute('r')!): row,
    };
    final drivingDetailsRows = {
      for (final row in drivingDetails.findAllElements('row'))
        if (int.tryParse(row.getAttribute('r') ?? '') != null) int.parse(row.getAttribute('r')!): row,
    };

    for (var r = 8; r <= 27; r++) {
      final row = trumanHomesRows[r];
      expect(row, isNotNull, reason: 'row $r must still exist (never dropped entirely)');
      expect(row!.getAttribute('ht'), isNull, reason: 'Truman Homes row $r must not carry a forced height');
      expect(row.getAttribute('customHeight'), isNull);
    }
    for (var r = 2; r <= 18; r++) {
      final row = drivingDetailsRows[r];
      expect(row, isNotNull, reason: 'row $r must still exist (never dropped entirely)');
      expect(row!.getAttribute('ht'), isNull, reason: 'Driving Details row $r must not carry a forced height');
      expect(row.getAttribute('customHeight'), isNull);
    }

    // Rows outside the managed range must still be protected as before.
    expect(trumanHomesRows[28]!.getAttribute('ht'), isNotNull, reason: 'Total row must keep its template height');

    await dir.delete(recursive: true);
  });
}
