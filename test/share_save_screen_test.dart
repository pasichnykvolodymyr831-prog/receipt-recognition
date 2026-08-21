// Section 12/14, Пакет 10: ShareSaveScreen refuses on entry with an
// explanation when NONE of a period's/cycle's files are on disk, instead of
// letting Share/Save try to operate on files that don't exist. Reworked in
// Пакет 8c of whimsical-booping-salamander.md from a 3-way mutually-
// exclusive radio choice (Mileage / Timesheet / Both) to independent
// checkboxes, so a MileageCycle's 3 files (1 Mileage + 2 Timesheets, one
// per constituent period) can each be selected on their own -- a fixed
// 3-radio design doesn't scale to 3 independently-gated files without an
// unwieldy combinatorial explosion of options.
//
// See period_archive_screen_test.dart for why every pump here is nested
// inside a single tester.runAsync -- this screen does real path_provider/
// dart:io work in initState, which hangs testWidgets otherwise in this
// environment.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/l10n/locale_controller.dart';
import 'package:expenseflow/models/mileage_cycle.dart';
import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/screens/share_save_screen.dart';
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

  final period = PayrollPeriod(
    key: 'p',
    start: DateTime(2026, 8, 9),
    end: DateTime(2026, 8, 23),
    due: DateTime(2026, 8, 21),
  );
  // Pairs with [period] into a real Mileage cycle (Aug 9 is the day right
  // after this ends) -- ShareSaveScreen resolves the cycle via
  // PeriodRepository, so it needs an actual partner on disk to find.
  final partner = PayrollPeriod(
    key: 'partner',
    start: DateTime(2026, 7, 24),
    end: DateTime(2026, 8, 8),
    due: DateTime(2026, 8, 6),
  );
  final cycle = MileageCycle(firstHalf: partner, secondHalf: period);

  Widget wrapForPeriod() {
    return AppLocale(
      controller: LocaleController('en'),
      child: MaterialApp(home: ShareSaveScreen.forPeriod(period: period)),
    );
  }

  Widget wrapForCycle() {
    return AppLocale(
      controller: LocaleController('en'),
      child: MaterialApp(home: ShareSaveScreen.forCycle(cycle: cycle)),
    );
  }

  Future<void> writePeriodsJson() async {
    final periodsFile = File('${docsDir.path}/payroll_periods.json');
    await periodsFile.writeAsString(jsonEncode({
      'periods': [period.toJson(), partner.toJson()],
    }));
  }

  Future<void> pumpAndSettle(WidgetTester tester) async {
    for (var i = 0; i < 5; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      await tester.pump(const Duration(milliseconds: 50));
    }
  }

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('share_save_screen_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  tearDown(() {
    docsDir.deleteSync(recursive: true);
  });

  testWidgets('forPeriod: refuses on entry with an explanation when no files exist at all', (tester) async {
    await tester.runAsync(() async {
      // Periods on disk so the cycle resolves, but no ensure*FileExists
      // call -- the files genuinely do not exist.
      await writePeriodsJson();
      await tester.pumpWidget(wrapForPeriod());
      await pumpAndSettle(tester);

      expect(find.textContaining('Excel files are no longer on this device'), findsOneWidget);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Save to device'), findsNothing);
    });
  });

  testWidgets(
      'forPeriod: an ambiguous file pair (Пакет 10, code-review 2026-08-19) surfaces the real error '
      'instead of silently claiming the files are unavailable', (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      // Keyed by the CYCLE's fileId, not period.fileId -- Mileage files are
      // cycle-keyed now.
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      File('${reportsDir.path}/MileageReport_${cycle.fileId}.xlsx').createSync();
      File('${reportsDir.path}/Prefix_MileageReport_${cycle.fileId}.xlsx').createSync();

      await tester.pumpWidget(wrapForPeriod());
      await pumpAndSettle(tester);

      expect(find.textContaining('Error:'), findsOneWidget,
          reason: 'a real error must surface distinctly, not be conflated with "files removed"');
      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
    });
  });

  testWidgets('forPeriod: shows both checkboxes pre-checked and enabled when both files exist', (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);

      await tester.pumpWidget(wrapForPeriod());
      await pumpAndSettle(tester);

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
      expect(find.text('Mileage Report'), findsOneWidget);
      expect(find.text('Timesheet'), findsOneWidget, reason: 'plain "Timesheet" label for the single-period case');
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Save to device'), findsOneWidget);

      final checkboxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(checkboxes, hasLength(2));
      expect(checkboxes.every((c) => c.value == true), true, reason: 'everything available defaults to checked');
    });
  });

  testWidgets('forPeriod: an orphaned period (no cycle yet) shows Mileage unchecked with the '
      '"not paired yet" caption, Timesheet still available on its own', (tester) async {
    await tester.runAsync(() async {
      // No partner written -- period is genuinely orphaned.
      final periodsFile = File('${docsDir.path}/payroll_periods.json');
      await periodsFile.writeAsString(jsonEncode({
        'periods': [period.toJson()],
      }));
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);

      await tester.pumpWidget(wrapForPeriod());
      await pumpAndSettle(tester);

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing,
          reason: 'Timesheet is available -- must not show the "nothing at all" banner');
      expect(find.textContaining('not yet paired'), findsOneWidget);

      final checkboxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      final mileageTile = checkboxes.firstWhere((c) => (c.title as Text).data == 'Mileage Report');
      expect(mileageTile.value, false);
      expect(mileageTile.onChanged, isNull, reason: 'disabled -- structurally can\'t exist yet');
    });
  });

  testWidgets('forCycle: shows 3 independently-labeled checkboxes, all pre-checked when everything exists',
      (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);
      await PeriodFileManager().ensureTimesheetFileExists(partner, AppSettings.defaults);
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);

      await tester.pumpWidget(wrapForCycle());
      await pumpAndSettle(tester);

      expect(find.text('Mileage Report'), findsOneWidget);
      expect(find.text('Timesheet: ${periodLabel(partner)}'), findsOneWidget,
          reason: 'qualified with the half\'s own label -- two Timesheets need to be told apart');
      expect(find.text('Timesheet: ${periodLabel(period)}'), findsOneWidget);
      expect(find.text('Timesheet'), findsNothing, reason: 'the plain unqualified label is only for forPeriod');

      final checkboxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      expect(checkboxes, hasLength(3));
      expect(checkboxes.every((c) => c.value == true), true);
    });
  });

  testWidgets(
      'forCycle: Mileage survives but only ONE half\'s Timesheet does -- mixed checkbox state, no top '
      'banner (Пакет 7\'s cycle-survives-independently scenario, now visible in Share/Save too)', (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);
      await PeriodFileManager().ensureTimesheetFileExists(partner, AppSettings.defaults);
      // period's (second half's) own Timesheet is deliberately never created.

      await tester.pumpWidget(wrapForCycle());
      await pumpAndSettle(tester);

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);

      final checkboxes = tester.widgetList<CheckboxListTile>(find.byType(CheckboxListTile)).toList();
      final mileageTile = checkboxes.firstWhere((c) => (c.title as Text).data == 'Mileage Report');
      final firstTimesheetTile =
          checkboxes.firstWhere((c) => (c.title as Text).data == 'Timesheet: ${periodLabel(partner)}');
      final secondTimesheetTile =
          checkboxes.firstWhere((c) => (c.title as Text).data == 'Timesheet: ${periodLabel(period)}');

      expect(mileageTile.value, true);
      expect(firstTimesheetTile.value, true);
      expect(secondTimesheetTile.value, false);
      expect(secondTimesheetTile.onChanged, isNull);
    });
  });

  testWidgets('unchecking every checkbox disables both Share and Save to device', (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);

      await tester.pumpWidget(wrapForPeriod());
      await pumpAndSettle(tester);

      for (final checkbox in find.byType(CheckboxListTile).evaluate().toList()) {
        await tester.tap(find.byWidget(checkbox.widget));
        await tester.pump();
      }

      final shareButton = tester.widget<FilledButton>(
        find.ancestor(of: find.text('Share'), matching: find.byType(FilledButton)),
      );
      final saveButton = tester.widget<OutlinedButton>(
        find.ancestor(of: find.text('Save to device'), matching: find.byType(OutlinedButton)),
      );
      expect(shareButton.onPressed, isNull);
      expect(saveButton.onPressed, isNull);
    });
  });
}
