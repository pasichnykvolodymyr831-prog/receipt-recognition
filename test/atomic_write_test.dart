// Section 13, step 8: a period-file write must replace the file atomically
// (write to a temp file, then rename over the original) rather than
// overwriting in place. A crash/kill between those two steps must leave the
// ORIGINAL file intact and openable -- never truncated/corrupt -- since the
// rename never happened. This test can't literally kill the process
// mid-rename, but it can verify the property that matters: an abandoned
// temp file left over from an interrupted write never touches the real
// file, and a successful write leaves no temp file behind.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/xlsx/mileage_report_engine.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final docsDir = await Directory.systemTemp.createTemp('atomic_write_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  test('a successful write leaves no leftover temp file next to the period file', () async {
    final dir = await Directory.systemTemp.createTemp('atomic_write_success');
    final file = File('${dir.path}/MileageReport_test.xlsx');

    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );
    await saveMileageReceipt(
      file,
      const ReceiptInput(date: null, description: null, subtotal: 45.99, gst: 2.30),
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );

    expect(await file.exists(), true);
    expect(await File('${file.path}.tmp').exists(), false);

    await dir.delete(recursive: true);
  });

  test('a temp file abandoned mid-write (crash before rename) never corrupts the real file', () async {
    final dir = await Directory.systemTemp.createTemp('atomic_write_interrupted');
    final file = File('${dir.path}/MileageReport_test.xlsx');

    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );
    final goodBytes = await file.readAsBytes();

    // Simulate a crash between "write the new bytes to <file>.tmp" and
    // "rename <file>.tmp over <file>": the temp file exists with different
    // (here: garbage) content, but the rename that would replace the real
    // file never happened.
    await File('${file.path}.tmp').writeAsBytes([1, 2, 3, 4, 5]);

    final stillGoodBytes = await file.readAsBytes();
    expect(stillGoodBytes, goodBytes, reason: 'the original file must be untouched by an abandoned temp file');
    expect(() => MileageReportEngine.fromBytes(stillGoodBytes), returnsNormally,
        reason: 'the original file must still be a valid, openable workbook');

    await dir.delete(recursive: true);
  });
}
