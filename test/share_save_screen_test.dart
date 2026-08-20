// Section 12/14, Пакет 10: ShareSaveScreen refuses on entry with an
// explanation when the period's files aren't on disk, instead of letting
// Share/Save try to operate on files that don't exist. See
// period_archive_screen_test.dart for why every pump here is nested inside
// a single tester.runAsync -- this screen does real path_provider/dart:io
// work in initState, which hangs testWidgets otherwise in this environment.
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
  // after this ends) -- ShareSaveScreen now resolves the cycle via
  // PeriodRepository, so it needs an actual partner on disk to find, unlike
  // before Пакет 2 when Mileage was looked up per-period directly.
  final partner = PayrollPeriod(
    key: 'partner',
    start: DateTime(2026, 7, 24),
    end: DateTime(2026, 8, 8),
    due: DateTime(2026, 8, 6),
  );
  final cycle = MileageCycle(firstHalf: partner, secondHalf: period);

  Widget wrap() {
    return AppLocale(
      controller: LocaleController('en'),
      child: MaterialApp(home: ShareSaveScreen(period: period)),
    );
  }

  Future<void> writePeriodsJson() async {
    final periodsFile = File('${docsDir.path}/payroll_periods.json');
    await periodsFile.writeAsString(jsonEncode({
      'periods': [period.toJson(), partner.toJson()],
    }));
  }

  setUp(() {
    docsDir = Directory.systemTemp.createTempSync('share_save_screen_test');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  tearDown(() {
    docsDir.deleteSync(recursive: true);
  });

  testWidgets('refuses on entry with an explanation when the files do not exist', (tester) async {
    await tester.runAsync(() async {
      // Periods on disk so the cycle resolves, but no ensure*FileExists
      // call -- the files genuinely do not exist.
      await writePeriodsJson();
      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsOneWidget);
      expect(find.text('Share'), findsNothing);
      expect(find.text('Save to device'), findsNothing);
    });
  });

  testWidgets(
      'an ambiguous file pair (Пакет 10, code-review 2026-08-19) surfaces the real error instead of '
      'silently claiming the files are unavailable', (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      // Keyed by the CYCLE's fileId, not period.fileId -- Mileage files are
      // cycle-keyed now.
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      File('${reportsDir.path}/MileageReport_${cycle.fileId}.xlsx').createSync();
      File('${reportsDir.path}/Prefix_MileageReport_${cycle.fileId}.xlsx').createSync();

      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.textContaining('Error:'), findsOneWidget,
          reason: 'a real error must surface distinctly, not be conflated with "files removed"');
      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
    });
  });

  testWidgets('shows the normal Share/Save controls when the files exist', (tester) async {
    await tester.runAsync(() async {
      await writePeriodsJson();
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);

      await tester.pumpWidget(wrap());
      for (var i = 0; i < 5; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
        await tester.pump(const Duration(milliseconds: 50));
      }

      expect(find.textContaining('Excel files are no longer on this device'), findsNothing);
      expect(find.text('Share'), findsOneWidget);
      expect(find.text('Save to device'), findsOneWidget);
    });
  });
}
