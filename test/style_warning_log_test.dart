// The style-integrity check (excel_integrity.dart) reports style drift as
// non-fatal warnings rather than blocking a write (see style_heal.dart for
// why -- writes proactively heal style first, so a residual warning means
// something the healer didn't anticipate). Those warnings must not be lost
// the same way the original style-loss bug was: this test checks that
// logStyleWarnings actually persists them to a durable file, not just to a
// transient debugPrint that only a live-attached debugger would ever see.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/services/style_warning_log.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  setUp(() async {
    docsDir = await Directory.systemTemp.createTemp('style_warning_log_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  tearDown(() async {
    await docsDir.delete(recursive: true);
  });

  test('does nothing when there are no warnings', () async {
    await logStyleWarnings('writeTimesheetSafely', 'Timesheet_test.xlsx', const []);

    final log = File('${docsDir.path}/style_warnings.log');
    expect(await log.exists(), false);
  });

  test('persists warnings to a durable log file with source, file name, and detail', () async {
    await logStyleWarnings('writeTimesheetSafely', 'Timesheet_test.xlsx', const [
      'Cell C9 border changed from the template',
    ]);

    final log = File('${docsDir.path}/style_warnings.log');
    expect(await log.exists(), true);
    final content = await log.readAsString();
    expect(content, contains('writeTimesheetSafely'));
    expect(content, contains('Timesheet_test.xlsx'));
    expect(content, contains('Cell C9 border changed from the template'));
  });

  test('appends rather than overwriting on repeated calls', () async {
    await logStyleWarnings('writeTimesheetSafely', 'Timesheet_test.xlsx', const ['first warning']);
    await logStyleWarnings('writeMileageReportSafely', 'MileageReport_test.xlsx', const ['second warning']);

    final log = File('${docsDir.path}/style_warnings.log');
    final lines = (await log.readAsString()).trim().split('\n');
    expect(lines.length, 2);
    expect(lines[0], contains('first warning'));
    expect(lines[1], contains('second warning'));
  });
}
