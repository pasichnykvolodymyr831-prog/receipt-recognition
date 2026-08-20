// Section 5/14, Пакет 10: the archive must list EVERY past period, whether
// or not its files still exist on disk (previously filtered to only
// periods with files, hiding a retention-cleaned period silently). Tapping
// a fileless period must show an explanation and disabled tiles, not a
// dead end.
//
// This screen does real dart:io/path_provider work inside FutureBuilders
// during build -- in this environment, testWidgets hangs forever on any
// real async gap unless the whole pumpWidget/pump sequence runs inside
// tester.runAsync (confirmed by isolating even a bare `await file.
// writeAsString(...)` inside a bare testWidgets body -- it hangs without
// runAsync, resolves instantly with it). Every pump below is therefore
// nested inside a single runAsync block, not just the setup.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/l10n/locale_controller.dart';
import 'package:expenseflow/models/mileage_cycle.dart';
import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/screens/period_archive_screen.dart';
import 'package:expenseflow/services/period_file_manager.dart';
import 'package:expenseflow/services/settings_repository.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory docsDir;

  final current = PayrollPeriod(
    key: 'current',
    start: DateTime(2026, 8, 9),
    end: DateTime(2026, 8, 23),
    due: DateTime(2026, 8, 21),
  );
  final pastWithFiles = PayrollPeriod(
    key: 'past-with-files',
    start: DateTime(2026, 7, 24),
    end: DateTime(2026, 8, 8),
    due: DateTime(2026, 8, 6),
  );
  final pastNoFiles = PayrollPeriod(
    key: 'past-no-files',
    start: DateTime(2026, 7, 9),
    end: DateTime(2026, 7, 23),
    due: DateTime(2026, 7, 21),
  );
  // pastWithFiles + current genuinely pair into a Mileage cycle (Aug 9 is
  // exactly the day after pastWithFiles ends) -- used below to create the
  // Mileage file under its real cycle-keyed fileId. pastNoFilesPartner
  // exists only so pastNoFiles also has a real cycle to resolve, needed for
  // the ambiguous-file test below (an orphaned period has no Mileage file
  // check to be ambiguous about at all).
  final pastNoFilesPartner = PayrollPeriod(
    key: 'past-no-files-partner',
    start: DateTime(2026, 6, 24),
    end: DateTime(2026, 7, 8),
    due: DateTime(2026, 7, 6),
  );

  Widget wrap() {
    return AppLocale(
      controller: LocaleController('en'),
      child: const MaterialApp(home: PeriodArchiveScreen()),
    );
  }

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('period_archive_screen_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  tearDown(() {
    docsDir.deleteSync(recursive: true);
  });

  testWidgets('lists every past period, including one whose files are gone', (tester) async {
    await tester.runAsync(() async {
      final periodsFile = File('${docsDir.path}/payroll_periods.json');
      await periodsFile.writeAsString(jsonEncode({
        'periods': [current.toJson(), pastWithFiles.toJson(), pastNoFiles.toJson()],
      }));
      // Only pastWithFiles actually gets real files on disk -- pastNoFiles
      // is exactly the "retention already cleaned it up" scenario.
      // pastWithFiles + current form a real Mileage cycle (see fixtures
      // above).
      await PeriodFileManager().ensureTimesheetFileExists(pastWithFiles, AppSettings.defaults);
      await PeriodFileManager()
          .ensureMileageFileExists(MileageCycle(firstHalf: pastWithFiles, secondHalf: current), AppSettings.defaults);

      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.text(periodLabel(pastWithFiles)), findsOneWidget);
      expect(find.text(periodLabel(pastNoFiles)), findsOneWidget,
          reason: 'a past period without files must still be listed, not hidden');
      expect(find.text(periodLabel(current)), findsNothing,
          reason: 'the current period is not part of the archive');
    });
  });

  testWidgets('opening a period without files shows an explanation and disabled tiles', (tester) async {
    await tester.runAsync(() async {
      final periodsFile = File('${docsDir.path}/payroll_periods.json');
      await periodsFile.writeAsString(jsonEncode({
        'periods': [current.toJson(), pastNoFiles.toJson()],
      }));

      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text(periodLabel(pastNoFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsOneWidget);
      // Only 4 tiles render in the archive (Add receipt/Driving Details are
      // hidden entirely there, not just disabled -- user decision,
      // 2026-08-19), each disabled since the files don't exist.
      expect(find.text('Files not available for this period'), findsNWidgets(4));
      expect(find.text('Add receipt'), findsNothing);
      expect(find.text('Driving Details'), findsNothing);
    });
  });

  testWidgets(
      'opening a period with an ambiguous file pair (Пакет 10, code-review 2026-08-19) surfaces the real '
      'error instead of silently claiming the files are unavailable', (tester) async {
    await tester.runAsync(() async {
      final periodsFile = File('${docsDir.path}/payroll_periods.json');
      await periodsFile.writeAsString(jsonEncode({
        'periods': [current.toJson(), pastNoFiles.toJson(), pastNoFilesPartner.toJson()],
      }));
      // Two candidate Mileage Report files for the same cycle -- exactly
      // the PeriodFileAmbiguousException scenario the Mileage-file
      // existence check can throw (e.g. a leftover unprefixed file
      // alongside a newly-prefixed one after a Settings name change). Keyed
      // by the CYCLE's fileId (pastNoFilesPartner + pastNoFiles), not
      // pastNoFiles' own -- Mileage files are cycle-keyed now.
      final cycle = MileageCycle(firstHalf: pastNoFilesPartner, secondHalf: pastNoFiles);
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      File('${reportsDir.path}/MileageReport_${cycle.fileId}.xlsx').createSync();
      File('${reportsDir.path}/Prefix_MileageReport_${cycle.fileId}.xlsx').createSync();

      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text(periodLabel(pastNoFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Error:'), findsOneWidget,
          reason: 'a real error must surface distinctly, not be conflated with "files removed"');
      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
    });
  });

  testWidgets('opening a period with files shows no explanation and enabled tiles', (tester) async {
    await tester.runAsync(() async {
      final periodsFile = File('${docsDir.path}/payroll_periods.json');
      await periodsFile.writeAsString(jsonEncode({
        'periods': [current.toJson(), pastWithFiles.toJson()],
      }));
      await PeriodFileManager().ensureTimesheetFileExists(pastWithFiles, AppSettings.defaults);
      await PeriodFileManager()
          .ensureMileageFileExists(MileageCycle(firstHalf: pastWithFiles, secondHalf: current), AppSettings.defaults);

      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      await tester.tap(find.text(periodLabel(pastWithFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
      expect(find.text('Files not available for this period'), findsNothing);
      expect(find.text('Receipts'), findsOneWidget);
      // The archive never offers adding new entries (user decision,
      // 2026-08-19) -- Add receipt/Driving Details are hidden entirely,
      // not just disabled.
      expect(find.text('Add receipt'), findsNothing);
      expect(find.text('Driving Details'), findsNothing);
    });
  });
}
