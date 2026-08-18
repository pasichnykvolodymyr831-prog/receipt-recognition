// Packet 6, section 5: file lookup must tolerate any (or no) prefix, since
// real files on the user's device were created by a pre-update build with
// no prefix at all, and a future Settings name change must not orphan
// files created under the old name. Uses PeriodFileManager's static,
// plain-Directory methods so most of this runs without path_provider --
// mirrors backup_manager_test.dart's split for the same reason.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/services/backup_manager.dart';
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

  group('ensureFilesExist (integration, section 5)', () {
    late Directory docsDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('period_file_manager_docs');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
    });

    final period = PayrollPeriod(
      key: '2026-08-09_2026-08-23',
      start: DateTime(2026, 8, 9),
      end: DateTime(2026, 8, 23),
      due: DateTime(2026, 8, 21, 16, 30),
      weekendAltDue: DateTime(2026, 8, 23, 8, 30),
      statHolidays: const [],
    );

    test('finds and leaves alone a real pre-existing unprefixed file, does not create a duplicate', () async {
      final reportsDir = Directory('${docsDir.path}/reports')..createSync(recursive: true);
      final realFile = File('${reportsDir.path}/MileageReport_2026-08-09_2026-08-23.xlsx');
      const marker = [1, 2, 3, 4, 5]; // stand-in for "real user data" -- must survive untouched.
      realFile.writeAsBytesSync(marker);
      final realTimesheet = File('${reportsDir.path}/Timesheet_2026-08-09_2026-08-23.xlsx');
      realTimesheet.writeAsBytesSync(marker);

      await PeriodFileManager().ensureFilesExist(
        period,
        AppSettings.defaults.copyWith(firstName: 'SomeoneElse'),
      );

      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, unorderedEquals(['MileageReport_2026-08-09_2026-08-23.xlsx', 'Timesheet_2026-08-09_2026-08-23.xlsx']),
          reason: 'a second, prefixed file must not be created alongside the real one');
      expect(realFile.readAsBytesSync(), marker, reason: 'the real file must be left untouched, not overwritten');
    });

    test('creates prefixed files when nothing exists yet', () async {
      await PeriodFileManager().ensureFilesExist(
        period,
        AppSettings.defaults.copyWith(firstName: 'Truman'),
      );

      final reportsDir = Directory('${docsDir.path}/reports');
      final entries = reportsDir.listSync().map((e) => e.uri.pathSegments.last).toList();
      expect(entries, unorderedEquals(['Truman_MileageReport_2026-08-09_2026-08-23.xlsx', 'Truman_Timesheet_2026-08-09_2026-08-23.xlsx']));
    });
  });

  group('cleanupAccordingToRetention (Пакет 21: backup deletion, audit 2026-08-18)', () {
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

    final oldPeriod = PayrollPeriod(
      key: 'old',
      start: DateTime(2020, 1, 9),
      end: DateTime(2020, 1, 23),
      due: DateTime(2020, 1, 21),
    );
    final currentPeriod = PayrollPeriod(
      key: 'current',
      start: DateTime(2026, 8, 9),
      end: DateTime(2026, 8, 23),
      due: DateTime(2026, 8, 21),
    );

    void writeReportAndBackup(String kind, String fileId) {
      File('${reportsDir.path}/${kind}_$fileId.xlsx').writeAsBytesSync([1]);
      File('${backupsDir.path}/${kind}_$fileId.xlsx.bak').writeAsBytesSync([1]);
    }

    test('deletes both the report file and its .bak when a period falls outside the retention window', () async {
      writeReportAndBackup('MileageReport', oldPeriod.fileId);
      writeReportAndBackup('Timesheet', oldPeriod.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx').existsSync(), false);
      expect(File('${backupsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx.bak').existsSync(), false,
          reason: 'the backup must be deleted alongside the report file, not left to accumulate forever');
      expect(File('${reportsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx').existsSync(), false);
      expect(File('${backupsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx.bak').existsSync(), false);
    });

    test('leaves the current period\'s files and backups untouched', () async {
      writeReportAndBackup('MileageReport', currentPeriod.fileId);
      writeReportAndBackup('Timesheet', currentPeriod.fileId);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.never,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${currentPeriod.fileId}.xlsx').existsSync(), true);
      expect(File('${backupsDir.path}/MileageReport_${currentPeriod.fileId}.xlsx.bak').existsSync(), true);
    });

    test('a report file with no backup on disk is still deleted cleanly (backup deletion is best-effort)', () async {
      File('${reportsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx').writeAsBytesSync([1]);
      File('${reportsDir.path}/Timesheet_${oldPeriod.fileId}.xlsx').writeAsBytesSync([1]);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx').existsSync(), false);
    });

    test('an ambiguous period is skipped entirely -- its backup is not touched either', () async {
      File('${reportsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx').writeAsBytesSync([1]);
      File('${reportsDir.path}/Prefix_MileageReport_${oldPeriod.fileId}.xlsx').writeAsBytesSync([1]);
      File('${backupsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx.bak').writeAsBytesSync([1]);

      await PeriodFileManager().cleanupAccordingToRetention(
        allPeriods: [oldPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${reportsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx').existsSync(), true);
      expect(File('${reportsDir.path}/Prefix_MileageReport_${oldPeriod.fileId}.xlsx').existsSync(), true);
      expect(File('${backupsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx.bak').existsSync(), true);
    });

    test('injecting a custom BackupManager is honored (constructor wiring)', () async {
      writeReportAndBackup('MileageReport', oldPeriod.fileId);
      final manager = PeriodFileManager(backupManager: BackupManager());

      await manager.cleanupAccordingToRetention(
        allPeriods: [oldPeriod, currentPeriod],
        currentPeriod: currentPeriod,
        retention: RetentionPolicy.oneMonth,
        now: DateTime(2026, 8, 20),
      );

      expect(File('${backupsDir.path}/MileageReport_${oldPeriod.fileId}.xlsx.bak').existsSync(), false);
    });
  });
}
