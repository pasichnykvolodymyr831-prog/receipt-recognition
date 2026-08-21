// Packet 6, section 5: file lookup must tolerate any (or no) prefix, since
// real files on the user's device were created by a pre-update build with
// no prefix at all, and a future Settings name change must not orphan
// files created under the old name. Uses PeriodFileManager's static,
// plain-Directory methods so most of this runs without path_provider --
// mirrors backup_manager_test.dart's split for the same reason.
import 'dart:io';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/models/mileage_cycle.dart';
import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/services/backup_manager.dart';
import 'package:expenseflow/services/period_file_manager.dart';
import 'package:expenseflow/services/settings_repository.dart';
import 'package:expenseflow/xlsx/xlsx_rels_compat.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('findPeriodFile', () {
    late Directory tempDir;

    setUp(() {
      tempDir = Directory.systemTemp.createTempSync('period_file_manager_test');
    });

    tearDown(() {
      tempDir.deleteSync(recursive: true);
    });

    test('finds a file with no prefix', () async {
      File('${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx').createSync();

      final found = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');

      expect(found?.path, '${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx');
    });

    test('finds a file with the current prefix', () async {
      File('${tempDir.path}/Truman_MileageReport_2026-08-09_2026-08-23.xlsx').createSync();

      final found = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');

      expect(found?.path, '${tempDir.path}/Truman_MileageReport_2026-08-09_2026-08-23.xlsx');
    });

    test('finds a file with a different (e.g. post-rename) prefix', () async {
      File('${tempDir.path}/John_Smith_MileageReport_2026-08-09_2026-08-23.xlsx').createSync();

      final found = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');

      expect(found?.path, '${tempDir.path}/John_Smith_MileageReport_2026-08-09_2026-08-23.xlsx');
    });

    test('returns null when nothing matches', () async {
      File('${tempDir.path}/MileageReport_2026-07-26_2026-08-08.xlsx').createSync(); // a different period

      final found = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');

      expect(found, isNull);
    });

    test('throws PeriodFileAmbiguousException listing both candidates when two match', () async {
      File('${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx').createSync();
      File('${tempDir.path}/Truman_MileageReport_2026-08-09_2026-08-23.xlsx').createSync();

      expect(
        () => PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23'),
        throwsA(
          isA<PeriodFileAmbiguousException>().having(
            (e) => e.candidateNames,
            'candidateNames',
            unorderedEquals(['MileageReport_2026-08-09_2026-08-23.xlsx', 'Truman_MileageReport_2026-08-09_2026-08-23.xlsx']),
          ),
        ),
      );
    });

    test('does not match the atomic-write temp file', () async {
      File('${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx.tmp').createSync();

      final found = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');

      expect(found, isNull);
    });

    test('does not match a backup file sitting in the same directory', () async {
      File('${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx.bak').createSync();

      final found = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');

      expect(found, isNull);
    });

    test('Mileage and Timesheet candidates for the same period do not collide', () async {
      File('${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx').createSync();
      File('${tempDir.path}/Timesheet_2026-08-09_2026-08-23.xlsx').createSync();

      final mileage = await PeriodFileManager.findPeriodFile(tempDir, 'MileageReport', '2026-08-09_2026-08-23');
      final timesheet = await PeriodFileManager.findPeriodFile(tempDir, 'Timesheet', '2026-08-09_2026-08-23');

      expect(mileage?.path, '${tempDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx');
      expect(timesheet?.path, '${tempDir.path}/Timesheet_2026-08-09_2026-08-23.xlsx');
    });
  });

  group('sanitizedFilenamePrefix', () {
    test('leaves a normal name unchanged', () {
      expect(PeriodFileManager.sanitizedFilenamePrefix('Truman'), 'Truman');
    });

    test('replaces illegal characters and whitespace with underscores, collapsed and trimmed', () {
      expect(PeriodFileManager.sanitizedFilenamePrefix('  John / Smith:Jr  '), 'John_Smith_Jr');
    });

    test('a name that is only illegal characters sanitizes to empty', () {
      expect(PeriodFileManager.sanitizedFilenamePrefix('///'), '');
    });

    test('an empty name sanitizes to empty', () {
      expect(PeriodFileManager.sanitizedFilenamePrefix(''), '');
    });

    test('whitespace-only name sanitizes to empty', () {
      expect(PeriodFileManager.sanitizedFilenamePrefix('   '), '');
    });
  });

  final firstHalf = PayrollPeriod(
    key: '2026-07-24_2026-08-08',
    start: DateTime(2026, 7, 24),
    end: DateTime(2026, 8, 8),
    due: DateTime(2026, 8, 6, 16, 30),
  );
  final period = PayrollPeriod(
    key: '2026-08-09_2026-08-23',
    start: DateTime(2026, 8, 9),
    end: DateTime(2026, 8, 23),
    due: DateTime(2026, 8, 21, 16, 30),
    weekendAltDue: DateTime(2026, 8, 23, 8, 30),
    statHolidays: const [],
  );
  final cycle = MileageCycle(firstHalf: firstHalf, secondHalf: period);

  group('ensureTimesheetFileExists (integration, section 5, Пакет 2 of '
      'whimsical-booping-salamander.md: split from the old combined ensureFilesExist)', () {
    late Directory docsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('period_file_manager_ts_docs');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
    });

    test('finds and leaves alone a real pre-existing unprefixed file, does not create a duplicate', () async {
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      final realTimesheet = File('${reportsDir.path}/Timesheet_2026-08-09_2026-08-23.xlsx');
      const marker = [1, 2, 3, 4, 5]; // stand-in for "real user data" -- must survive untouched.
      realTimesheet.writeAsBytesSync(marker);

      await PeriodFileManager().ensureTimesheetFileExists(
        period,
        AppSettings.defaults.copyWith(firstName: 'SomeoneElse'),
      );

      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['Timesheet_2026-08-09_2026-08-23.xlsx'],
          reason: 'a second, prefixed file must not be created alongside the real one');
      expect(realTimesheet.readAsBytesSync(), marker, reason: 'the real file must be left untouched, not overwritten');
    });

    test('creates a prefixed file when nothing exists yet', () async {
      await PeriodFileManager().ensureTimesheetFileExists(
        period,
        AppSettings.defaults.copyWith(firstName: 'Truman'),
      );

      final reportsDir = Directory('${docsDir.path}/reports');
      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['Truman_Timesheet_2026-08-09_2026-08-23.xlsx']);
    });
  });

  group('ensureMileageFileExists (integration, section 5/6.2, Пакет 2 of '
      'whimsical-booping-salamander.md: one file per 4-week Mileage cycle, not per 2-week period)', () {
    late Directory docsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('period_file_manager_mg_docs');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
    });

    test('finds and leaves alone a real pre-existing unprefixed file, does not create a duplicate', () async {
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      final realFile = File('${reportsDir.path}/MileageReport_2026-07-24_2026-08-23.xlsx');
      const marker = [1, 2, 3, 4, 5]; // stand-in for "real user data" -- must survive untouched.
      realFile.writeAsBytesSync(marker);

      await PeriodFileManager().ensureMileageFileExists(
        cycle,
        AppSettings.defaults.copyWith(firstName: 'SomeoneElse'),
      );

      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['MileageReport_2026-07-24_2026-08-23.xlsx'],
          reason: 'a second, prefixed file must not be created alongside the real one, named by the CYCLE fileId');
      expect(realFile.readAsBytesSync(), marker, reason: 'the real file must be left untouched, not overwritten');
    });

    test('creates a prefixed file, named by the cycle fileId (not either half\'s own), when nothing exists yet',
        () async {
      await PeriodFileManager().ensureMileageFileExists(
        cycle,
        AppSettings.defaults.copyWith(firstName: 'Truman'),
      );

      final reportsDir = Directory('${docsDir.path}/reports');
      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['Truman_MileageReport_2026-07-24_2026-08-23.xlsx']);
    });

    test('the Kilometers row date (A8) reflects the END OF THE WHOLE CYCLE, not just the opening half '
        '(section 6.2/13 п.1а -- regression test for the periodEnd: cycle.end vs firstHalf.end distinction)',
        () async {
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);

      final file = await PeriodFileManager().mileageReportFile(cycle);
      final excel = Excel.decodeBytes(normalizeXlsxRelationshipTargets(await file.readAsBytes()));
      final a8 = excel.sheets['Truman Homes']!.cell(CellIndex.indexByString('A8')).value;
      final date = (a8 as DateCellValue).asDateTimeLocal();
      expect(DateTime(date.year, date.month, date.day), cycle.end,
          reason: 'must be secondHalf.end (cycle.end), not firstHalf.end');
    });
  });

  group('ensureMileageFileExists legacy migration (whimsical-booping-salamander.md, Пакет 2: a real user '
      'device has a Mileage file created by a pre-cycle build, keyed by a single PayrollPeriod.fileId)', () {
    late Directory docsDir;
    late Directory reportsDir;
    late Directory backupsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('period_file_manager_migration_docs');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
      reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      backupsDir = Directory('${docsDir.path}/backups')..createSync(recursive: true);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
    });

    test('renames a legacy file keyed by the SECOND half\'s own fileId to the cycle fileId, preserving its bytes',
        () async {
      final legacy = File('${reportsDir.path}/Truman_MileageReport_${period.fileId}.xlsx');
      const realData = [9, 9, 9, 9]; // stand-in for a real receipt/trip the user already entered.
      legacy.writeAsBytesSync(realData);

      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults.copyWith(firstName: 'Truman'));

      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['Truman_MileageReport_${cycle.fileId}.xlsx'],
          reason: 'the legacy file must be renamed in place, not left behind alongside a fresh blank one');
      expect(File('${reportsDir.path}/Truman_MileageReport_${cycle.fileId}.xlsx').readAsBytesSync(), realData,
          reason: 'the real data must survive the rename byte-for-byte');
    });

    // AppSettings.defaults.firstName is 'Truman' (the app's real shipped
    // default, per section 5) -- these tests use an explicit empty
    // firstName wherever an unprefixed filename is expected, rather than
    // relying on AppSettings.defaults to mean "no prefix".
    final noPrefix = AppSettings.defaults.copyWith(firstName: '');

    test('renames a legacy file keyed by the FIRST half\'s own fileId to the cycle fileId', () async {
      final legacy = File('${reportsDir.path}/MileageReport_${firstHalf.fileId}.xlsx');
      const realData = [7, 7, 7];
      legacy.writeAsBytesSync(realData);

      await PeriodFileManager().ensureMileageFileExists(cycle, noPrefix);

      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['MileageReport_${cycle.fileId}.xlsx']);
      expect(File('${reportsDir.path}/MileageReport_${cycle.fileId}.xlsx').readAsBytesSync(), realData);
    });

    test('migrates the file\'s .bak alongside it, so the next write does not orphan a stale backup', () async {
      File('${reportsDir.path}/Truman_MileageReport_${period.fileId}.xlsx').writeAsBytesSync([1, 2, 3]);
      final legacyBackup = File('${backupsDir.path}/Truman_MileageReport_${period.fileId}.xlsx.bak')
        ..writeAsBytesSync([4, 5, 6]);

      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults.copyWith(firstName: 'Truman'));

      expect(legacyBackup.existsSync(), false);
      expect(File('${backupsDir.path}/Truman_MileageReport_${cycle.fileId}.xlsx.bak').readAsBytesSync(), [4, 5, 6]);
    });

    test('a legacy file with no backup on disk is still migrated cleanly (backup migration is best-effort)',
        () async {
      File('${reportsDir.path}/MileageReport_${period.fileId}.xlsx').writeAsBytesSync([1]);

      await PeriodFileManager().ensureMileageFileExists(cycle, noPrefix);

      expect(File('${reportsDir.path}/MileageReport_${cycle.fileId}.xlsx').existsSync(), true);
    });

    test('throws PeriodFileAmbiguousException when BOTH halves independently have their own legacy file -- '
        'never guesses which real data to keep', () async {
      File('${reportsDir.path}/MileageReport_${firstHalf.fileId}.xlsx').writeAsBytesSync([1]);
      File('${reportsDir.path}/MileageReport_${period.fileId}.xlsx').writeAsBytesSync([2]);

      expect(
        () => PeriodFileManager().ensureMileageFileExists(cycle, noPrefix),
        throwsA(isA<PeriodFileAmbiguousException>()),
      );
    });

    test('no migration happens (creates fresh) when no legacy file exists under either half\'s fileId', () async {
      await PeriodFileManager().ensureMileageFileExists(cycle, noPrefix);

      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, ['MileageReport_${cycle.fileId}.xlsx']);
    });
  });

  group('writeHeaderIfFilesExist (Пакет 9: Settings name/phone propagation; '
      'takes an optional MileageCycle as of Пакет 2 of whimsical-booping-salamander.md)', () {
    late Directory docsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('period_file_manager_header_docs');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
    });

    test('writes B3/C2/C6 to both files when they already exist', () async {
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);

      await PeriodFileManager()
          .writeHeaderIfFilesExist(period, cycle: cycle, employeeName: 'New Name', phone: '555-1234');

      final mileageFile = await PeriodFileManager().mileageReportFile(cycle);
      final mileage = Excel.decodeBytes(normalizeXlsxRelationshipTargets(await mileageFile.readAsBytes()));
      expect(mileage.sheets['Truman Homes']!.cell(CellIndex.indexByString('B3')).value.toString(),
          contains('New Name'));

      final timesheetFile = await PeriodFileManager().timesheetFile(period);
      final timesheet = Excel.decodeBytes(normalizeXlsxRelationshipTargets(await timesheetFile.readAsBytes()));
      expect(timesheet.sheets['Sheet1']!.cell(CellIndex.indexByString('C2')).value.toString(),
          contains('New Name'));
      expect(timesheet.sheets['Sheet1']!.cell(CellIndex.indexByString('C6')).value.toString(),
          contains('555-1234'));
    });

    test('does not touch the period label (M3/C5) -- only the name/phone cells', () async {
      await PeriodFileManager().ensureMileageFileExists(cycle, AppSettings.defaults);
      final mileageFile = await PeriodFileManager().mileageReportFile(cycle);
      final before = Excel.decodeBytes(normalizeXlsxRelationshipTargets(await mileageFile.readAsBytes()));
      final labelBefore = before.sheets['Truman Homes']!.cell(CellIndex.indexByString('M3')).value.toString();

      await PeriodFileManager()
          .writeHeaderIfFilesExist(period, cycle: cycle, employeeName: 'New Name', phone: '555-1234');

      final after = Excel.decodeBytes(normalizeXlsxRelationshipTargets(await mileageFile.readAsBytes()));
      expect(after.sheets['Truman Homes']!.cell(CellIndex.indexByString('M3')).value.toString(), labelBefore);
    });

    test('is a no-op when neither file exists yet (period/cycle not created)', () async {
      await PeriodFileManager()
          .writeHeaderIfFilesExist(period, cycle: cycle, employeeName: 'New Name', phone: '555-1234');

      final mileageFile = await PeriodFileManager().mileageReportFile(cycle);
      final timesheetFile = await PeriodFileManager().timesheetFile(period);
      expect(await mileageFile.exists(), false, reason: 'must not create the file as a side effect');
      expect(await timesheetFile.exists(), false, reason: 'must not create the file as a side effect');
    });

    test('touches only the Timesheet file when cycle is null (period not yet paired)', () async {
      await PeriodFileManager().ensureTimesheetFileExists(period, AppSettings.defaults);

      await PeriodFileManager().writeHeaderIfFilesExist(period, employeeName: 'New Name', phone: '555-1234');

      final timesheetFile = await PeriodFileManager().timesheetFile(period);
      final timesheet = Excel.decodeBytes(normalizeXlsxRelationshipTargets(await timesheetFile.readAsBytes()));
      expect(timesheet.sheets['Sheet1']!.cell(CellIndex.indexByString('C2')).value.toString(),
          contains('New Name'));
    });
  });

  group('periodsOutsideRetention (Пакет 9: the pure filter cleanupAccordingToRetention and the '
      'Settings confirmation-count dialog both share)', () {
    final oldPeriod = PayrollPeriod(
      key: 'old',
      start: DateTime(2020, 1, 9),
      end: DateTime(2020, 1, 23),
      due: DateTime(2020, 1, 21),
    );
    final recentPeriod = PayrollPeriod(
      key: 'recent',
      start: DateTime(2026, 8, 9),
      end: DateTime(2026, 8, 23),
      due: DateTime(2026, 8, 21),
    );
    final currentPeriod = PayrollPeriod(
      key: 'current',
      start: DateTime(2026, 8, 24),
      end: DateTime(2026, 9, 8),
      due: DateTime(2026, 9, 6),
    );

    test('excludes the current period and periods within the window, keeps ones older than it', () {
      final result = PeriodFileManager().periodsOutsideRetention(
        allPeriods: [oldPeriod, recentPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(result, [oldPeriod]);
    });

    test('a `never` policy returns every period except the current one', () {
      final result = PeriodFileManager().periodsOutsideRetention(
        allPeriods: [oldPeriod, recentPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.never,
        now: DateTime(2026, 8, 20),
      );

      expect(result, [oldPeriod, recentPeriod]);
    });

    test('an empty result when nothing falls outside the window', () {
      final result = PeriodFileManager().periodsOutsideRetention(
        allPeriods: [recentPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.oneYear,
        now: DateTime(2026, 8, 20),
      );

      expect(result, isEmpty);
    });
  });

  group('cleanupAccordingToRetention (Пакет 21: backup deletion, audit 2026-08-18; reworked onto '
      'cycles for Mileage in Пакет 7 of whimsical-booping-salamander.md -- ⚠️ the plan\'s single '
      'flagged real data-loss risk in this whole feature)', () {
    late Directory docsDir;
    late Directory reportsDir;
    late Directory backupsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('period_file_manager_retention_docs');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
      reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      backupsDir = Directory('${docsDir.path}/backups')..createSync(recursive: true);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
    });

    // An old, fully-aged-out cycle -- both halves are old enough that
    // neither could ever be "current".
    final oldFirstHalf = PayrollPeriod(
      key: 'old-first',
      start: DateTime(2019, 12, 24),
      end: DateTime(2020, 1, 8),
      due: DateTime(2020, 1, 6),
    );
    final oldPeriod = PayrollPeriod(
      key: 'old',
      start: DateTime(2020, 1, 9),
      end: DateTime(2020, 1, 23),
      due: DateTime(2020, 1, 21),
    );
    final oldCycle = MileageCycle(firstHalf: oldFirstHalf, secondHalf: oldPeriod);

    // The cycle that's live "today" (2026-08-20) -- currentPeriod is its
    // SECOND half, exactly the scenario the plan's regression test targets:
    // firstHalf is no longer literally "current" once the calendar crosses
    // into the second half, but the cycle's shared Mileage file still is.
    final firstHalf = PayrollPeriod(
      key: 'first-half',
      start: DateTime(2026, 7, 24),
      end: DateTime(2026, 8, 8),
      due: DateTime(2026, 8, 6),
    );
    final currentPeriod = PayrollPeriod(
      key: 'current',
      start: DateTime(2026, 8, 9),
      end: DateTime(2026, 8, 23),
      due: DateTime(2026, 8, 21),
    );
    final currentCycle = MileageCycle(firstHalf: firstHalf, secondHalf: currentPeriod);

    void writeReportAndBackup(String kind, String fileId) {
      File('${reportsDir.path}/${kind}_$fileId.xlsx').writeAsBytesSync([1]);
      File('${backupsDir.path}/${kind}_$fileId.xlsx.bak').writeAsBytesSync([1]);
    }

    test(
        '⚠️ REGRESSION (Пакет 7\'s whole reason to exist): when the current period is a cycle\'s SECOND '
        'half, the cycle\'s shared Mileage file survives retention=never even though the FIRST half is '
        'no longer literally "current" -- the first half\'s own Timesheet is still cleaned up normally, '
        'proving the Mileage side is genuinely cycle-scoped, not silently piggy-backing on period identity',
        () async {
      writeReportAndBackup('MileageReport', currentCycle.fileId); // the one shared file
      writeReportAndBackup('Timesheet', firstHalf.fileId);
      writeReportAndBackup('Timesheet', currentPeriod.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [firstHalf, currentPeriod],
        currentPeriod: currentPeriod, // current = the cycle's SECOND half
        allCycles: [currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.never,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${currentCycle.fileId}.xlsx').existsSync(), true,
          reason: 'the cycle is still current (via its second half) -- must survive, live data at risk otherwise');
      expect(File('${backupsDir.path}/MileageReport_${currentCycle.fileId}.xlsx.bak').existsSync(), true);
      expect(File('${reportsDir.path}/Timesheet_${firstHalf.fileId}.xlsx').existsSync(), false,
          reason: 'the first half is no longer "current" at the period level -- its own Timesheet '
              'must still age out exactly as before, unaffected by the cycle-level Mileage change');
      expect(File('${reportsDir.path}/Timesheet_${currentPeriod.fileId}.xlsx').existsSync(), true,
          reason: 'currentPeriod itself is still excluded on the Timesheet side too');
    });

    test('a non-current cycle\'s Mileage file (and its .bak) is deleted once it ages out', () async {
      writeReportAndBackup('MileageReport', oldCycle.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldFirstHalf, oldPeriod, firstHalf, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: [oldCycle, currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldCycle.fileId}.xlsx').existsSync(), false);
      expect(File('${backupsDir.path}/MileageReport_${oldCycle.fileId}.xlsx.bak').existsSync(), false,
          reason: 'the backup must be deleted alongside the report file, not left to accumulate forever');
    });

    test('deletes both the report file and its .bak when a period falls outside the retention window '
        '(Timesheet side, unchanged from before Пакет 7)', () async {
      writeReportAndBackup('Timesheet', oldPeriod.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: const [],
        currentCycle: null,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx').existsSync(), false);
      expect(File('${backupsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx.bak').existsSync(), false);
    });

    test('leaves the current period\'s Timesheet and the current cycle\'s Mileage file untouched', () async {
      writeReportAndBackup('MileageReport', currentCycle.fileId);
      writeReportAndBackup('Timesheet', currentPeriod.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [firstHalf, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: [currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.never,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${currentCycle.fileId}.xlsx').existsSync(), true);
      expect(File('${backupsDir.path}/MileageReport_${currentCycle.fileId}.xlsx.bak').existsSync(), true);
      expect(File('${reportsDir.path}/Timesheet_${currentPeriod.fileId}.xlsx').existsSync(), true);
    });

    test('a cycle Mileage report file with no backup on disk is still deleted cleanly (best-effort)', () async {
      File('${reportsDir.path}/MileageReport_${oldCycle.fileId}.xlsx').writeAsBytesSync([1]);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldFirstHalf, oldPeriod, firstHalf, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: [oldCycle, currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldCycle.fileId}.xlsx').existsSync(), false);
    });

    test('an ambiguous cycle Mileage file is skipped entirely -- its backup is not touched either', () async {
      File('${reportsDir.path}/MileageReport_${oldCycle.fileId}.xlsx').writeAsBytesSync([1]);
      File('${reportsDir.path}/Prefix_MileageReport_${oldCycle.fileId}.xlsx').writeAsBytesSync([1]);
      File('${backupsDir.path}/MileageReport_${oldCycle.fileId}.xlsx.bak').writeAsBytesSync([1]);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldFirstHalf, oldPeriod, firstHalf, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: [oldCycle, currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldCycle.fileId}.xlsx').existsSync(), true);
      expect(File('${reportsDir.path}/Prefix_MileageReport_${oldCycle.fileId}.xlsx').existsSync(), true);
      expect(File('${backupsDir.path}/MileageReport_${oldCycle.fileId}.xlsx.bak').existsSync(), true);
    });

    test('an ambiguous period is skipped on the Timesheet side too -- its backup is not touched either', () async {
      File('${reportsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx').writeAsBytesSync([1]);
      File('${reportsDir.path}/Prefix_Timesheet_${oldPeriod.fileId}.xlsx').writeAsBytesSync([1]);
      File('${backupsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx.bak').writeAsBytesSync([1]);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: const [],
        currentCycle: null,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx').existsSync(), true);
      expect(File('${reportsDir.path}/Prefix_Timesheet_${oldPeriod.fileId}.xlsx').existsSync(), true);
      expect(File('${backupsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx.bak').existsSync(), true);
    });

    test('injecting a custom BackupManager is honored (constructor wiring), both sides', () async {
      writeReportAndBackup('MileageReport', oldCycle.fileId);
      writeReportAndBackup('Timesheet', oldPeriod.fileId);
      final manager = PeriodFileManager(backupManager: BackupManager());

      await manager.cleanupAccordingToRetention(
        allPeriods: [oldFirstHalf, oldPeriod, firstHalf, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: [oldCycle, currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${backupsDir.path}/MileageReport_${oldCycle.fileId}.xlsx.bak').existsSync(), false);
      expect(File('${backupsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx.bak').existsSync(), false);
    });

    test('a `never` policy deletes every non-current cycle\'s Mileage file, mirroring the Timesheet side',
        () async {
      writeReportAndBackup('MileageReport', oldCycle.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldFirstHalf, oldPeriod, firstHalf, currentPeriod],
        currentPeriod: currentPeriod,
        allCycles: [oldCycle, currentCycle],
        currentCycle: currentCycle,
        retention: RetentionPolicy.never,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldCycle.fileId}.xlsx').existsSync(), false);
    });
  });
}
