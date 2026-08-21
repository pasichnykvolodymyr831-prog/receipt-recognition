// Section 5/14, Пакет 10: the archive must list EVERY past period/cycle,
// whether or not its files still exist on disk (previously filtered to only
// entries with files, hiding a retention-cleaned one silently). Tapping a
// fileless entry must show an explanation and disabled tiles, not a dead
// end. Reworked in Пакет 8a of whimsical-booping-salamander.md: the list is
// now cycles (4-week Mileage groupings) plus any past period that never
// paired into one (the real seed-data shape: the very first period ever
// recorded structurally can't have a predecessor).
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

  // A fully-past cycle (both halves already over) -- used for the
  // "has files" / "ambiguous" scenarios below.
  final cycleWithFilesFirst = PayrollPeriod(
    key: 'cycle-with-files-first',
    start: DateTime(2026, 6, 24),
    end: DateTime(2026, 7, 8),
    due: DateTime(2026, 7, 6),
  );
  final cycleWithFilesSecond = PayrollPeriod(
    key: 'cycle-with-files-second',
    start: DateTime(2026, 7, 9),
    end: DateTime(2026, 7, 23),
    due: DateTime(2026, 7, 21),
  );
  final cycleWithFiles = MileageCycle(firstHalf: cycleWithFilesFirst, secondHalf: cycleWithFilesSecond);

  // A separate fully-past cycle with no files at all -- the "retention
  // already cleaned it up" scenario, now at the cycle level.
  final cycleNoFilesFirst = PayrollPeriod(
    key: 'cycle-no-files-first',
    start: DateTime(2026, 5, 24),
    end: DateTime(2026, 6, 8),
    due: DateTime(2026, 6, 6),
  );
  final cycleNoFilesSecond = PayrollPeriod(
    key: 'cycle-no-files-second',
    start: DateTime(2026, 6, 9),
    end: DateTime(2026, 6, 23),
    due: DateTime(2026, 6, 21),
  );
  final cycleNoFiles = MileageCycle(firstHalf: cycleNoFilesFirst, secondHalf: cycleNoFilesSecond);

  // A genuinely orphaned past period -- no predecessor present at all,
  // mirroring the real seed data's very first period (2026-03-09..23).
  final orphanPeriod = PayrollPeriod(
    key: 'orphan',
    start: DateTime(2026, 3, 9),
    end: DateTime(2026, 3, 23),
    due: DateTime(2026, 3, 21),
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

  Future<void> writePeriods(List<PayrollPeriod> periods) async {
    final periodsFile = File('${docsDir.path}/payroll_periods.json');
    await periodsFile.writeAsString(jsonEncode({'periods': periods.map((p) => p.toJson()).toList()}));
  }

  Future<void> pumpAndSettle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  testWidgets('lists every past cycle (by cycle label) and every orphaned past period, excludes current',
      (tester) async {
    await tester.runAsync(() async {
      await writePeriods([
        current,
        cycleWithFilesFirst,
        cycleWithFilesSecond,
        cycleNoFilesFirst,
        cycleNoFilesSecond,
        orphanPeriod,
      ]);
      await PeriodFileManager().ensureTimesheetFileExists(cycleWithFilesFirst, AppSettings.defaults);
      await PeriodFileManager().ensureMileageFileExists(cycleWithFiles, AppSettings.defaults);

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      expect(find.text(cycleLabel(cycleWithFiles)), findsOneWidget);
      expect(find.text(cycleLabel(cycleNoFiles)), findsOneWidget,
          reason: 'a past cycle without files must still be listed, not hidden');
      expect(find.text(periodLabel(orphanPeriod)), findsOneWidget,
          reason: 'an orphaned past period (no cycle partner) must still be listed on its own');
      expect(find.text('Timesheet only -- no Mileage cycle partner'), findsOneWidget);
      expect(find.text(periodLabel(current)), findsNothing,
          reason: 'the current period/cycle is not part of the archive');
    });
  });

  testWidgets(
      'opening a cycle with no files at all shows the explanation and all 5 tiles disabled '
      '(Receipts/Trips/Timesheet x2/Share-Save -- Пакет 8b\'s own screen, not PeriodActionTiles)',
      (tester) async {
    await tester.runAsync(() async {
      await writePeriods([current, cycleNoFilesFirst, cycleNoFilesSecond]);

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      await tester.tap(find.text(cycleLabel(cycleNoFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsOneWidget);
      expect(find.text('Files not available for this period'), findsNWidgets(5));
      expect(find.text('Receipts'), findsOneWidget);
      expect(find.text('Trips'), findsOneWidget);
      expect(find.text('Timesheet: ${periodLabel(cycleNoFilesFirst)}'), findsOneWidget);
      expect(find.text('Timesheet: ${periodLabel(cycleNoFilesSecond)}'), findsOneWidget);
      expect(find.text('Share / Save'), findsOneWidget);
    });
  });

  testWidgets(
      'a cycle whose Mileage survived but only ONE half\'s Timesheet did shows mixed tile availability, '
      'no top banner -- the whole point of Пакет 8b\'s independent per-file checks', (tester) async {
    await tester.runAsync(() async {
      await writePeriods([current, cycleNoFilesFirst, cycleNoFilesSecond]);
      await PeriodFileManager().ensureMileageFileExists(cycleNoFiles, AppSettings.defaults);
      await PeriodFileManager().ensureTimesheetFileExists(cycleNoFilesFirst, AppSettings.defaults);
      // cycleNoFilesSecond's own Timesheet is deliberately never created.

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      await tester.tap(find.text(cycleLabel(cycleNoFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing,
          reason: 'not everything is missing -- the top banner must not show');
      // Receipts/Trips (Mileage) and the first half's Timesheet are
      // available; only the second half's Timesheet subtile is disabled.
      expect(find.text('Files not available for this period'), findsOneWidget);
    });
  });

  testWidgets(
      'opening a cycle with an ambiguous Mileage file (Пакет 10, code-review 2026-08-19) surfaces the real '
      'error instead of silently claiming the files are unavailable', (tester) async {
    await tester.runAsync(() async {
      await writePeriods([current, cycleNoFilesFirst, cycleNoFilesSecond]);
      // Two candidate Mileage Report files for the same cycle -- exactly
      // the PeriodFileAmbiguousException scenario the Mileage-file
      // existence check can throw (e.g. a leftover unprefixed file
      // alongside a newly-prefixed one after a Settings name change).
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      File('${reportsDir.path}/MileageReport_${cycleNoFiles.fileId}.xlsx').createSync();
      File('${reportsDir.path}/Prefix_MileageReport_${cycleNoFiles.fileId}.xlsx').createSync();

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      await tester.tap(find.text(cycleLabel(cycleNoFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Error:'), findsOneWidget,
          reason: 'a real error must surface distinctly, not be conflated with "files removed"');
      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
    });
  });

  testWidgets('opening a cycle with everything (Mileage + both Timesheets) shows no explanation, all 5 '
      'tiles enabled', (tester) async {
    await tester.runAsync(() async {
      await writePeriods([current, cycleWithFilesFirst, cycleWithFilesSecond]);
      await PeriodFileManager().ensureTimesheetFileExists(cycleWithFilesFirst, AppSettings.defaults);
      await PeriodFileManager().ensureTimesheetFileExists(cycleWithFilesSecond, AppSettings.defaults);
      await PeriodFileManager().ensureMileageFileExists(cycleWithFiles, AppSettings.defaults);

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      await tester.tap(find.text(cycleLabel(cycleWithFiles)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
      expect(find.text('Files not available for this period'), findsNothing);
      expect(find.text('Receipts'), findsOneWidget);
      expect(find.text('Trips'), findsOneWidget);
      expect(find.text('Timesheet: ${periodLabel(cycleWithFilesFirst)}'), findsOneWidget);
      expect(find.text('Timesheet: ${periodLabel(cycleWithFilesSecond)}'), findsOneWidget);
      expect(find.text('Share / Save'), findsOneWidget);
      // The archive never offers adding new entries (user decision,
      // 2026-08-19) -- Add receipt/Driving Details don't exist on this
      // screen at all.
      expect(find.text('Add receipt'), findsNothing);
      expect(find.text('Driving Details'), findsNothing);
    });
  });

  testWidgets(
      'opening an orphaned period whose Timesheet exists shows enabled tiles even though Mileage can '
      'never exist for it (Пакет 8a: OR, not AND -- the whole point of this scenario)', (tester) async {
    await tester.runAsync(() async {
      await writePeriods([current, orphanPeriod]);
      await PeriodFileManager().ensureTimesheetFileExists(orphanPeriod, AppSettings.defaults);

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      await tester.tap(find.text(periodLabel(orphanPeriod)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
      expect(find.text('Files not available for this period'), findsNothing);
      // Timesheet itself is genuinely accessible.
      expect(find.text('Timesheet'), findsOneWidget);
    });
  });

  testWidgets('opening an orphaned period with no files at all shows the explanation, all tiles disabled',
      (tester) async {
    await tester.runAsync(() async {
      await writePeriods([current, orphanPeriod]);

      await tester.pumpWidget(wrap());
      await pumpAndSettle(tester);

      await tester.tap(find.text(periodLabel(orphanPeriod)));
      for (var i = 0; i < 8; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 100));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsOneWidget);
      expect(find.text('Files not available for this period'), findsNWidgets(4));
    });
  });
}
