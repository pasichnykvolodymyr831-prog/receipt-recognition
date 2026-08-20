import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/payroll_period.dart';
import 'backup_manager.dart';
import 'safe_xlsx_write.dart';
import 'settings_repository.dart';

String periodLabel(PayrollPeriod period) {
  String fmt(DateTime d) => '${_month(d.month)} ${d.day}';
  return '${fmt(period.start)} - ${fmt(period.end)}, ${period.end.year}';
}

const _months = [
  'Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec',
];
String _month(int m) => _months[m - 1];

/// Thrown when more than one file on disk matches a period's file-name
/// pattern (section 5) -- e.g. an old unprefixed file left behind alongside
/// a newly-prefixed one after a Settings name change. Never silently pick
/// one: the unpicked file's data would become invisible to the user, the
/// same principle as the duplicate-Kilometers-row check (section 13 п.1а).
class PeriodFileAmbiguousException implements Exception {
  final String kind; // 'MileageReport' or 'Timesheet'
  final List<String> candidateNames;
  const PeriodFileAmbiguousException(this.kind, this.candidateNames);
  @override
  String toString() =>
      'PeriodFileAmbiguousException: multiple $kind files found for this period: ${candidateNames.join(", ")}';
}

/// Creates, locates, and cleans up the per-period xlsx files (section 5)
/// in a flat `reports/` folder under the app's documents directory. File
/// names already encode the period range, so no per-period subfolder is
/// needed: `<prefix_>MileageReport_<start>_<end>.xlsx`,
/// `<prefix_>Timesheet_<start>_<end>.xlsx`, where `<prefix_>` is the
/// sanitized Settings first name at the time of creation, or nothing.
class PeriodFileManager {
  PeriodFileManager({BackupManager? backupManager}) : _backupManager = backupManager ?? BackupManager();

  final BackupManager _backupManager;

  Future<Directory> _reportsDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final reports = Directory('${dir.path}/reports');
    if (!await reports.exists()) {
      await reports.create(recursive: true);
    }
    return reports;
  }

  Future<File> mileageReportFile(PayrollPeriod period) async {
    final dir = await _reportsDir();
    final existing = await findPeriodFile(dir, 'MileageReport', period.fileId);
    return existing ?? File('${dir.path}/MileageReport_${period.fileId}.xlsx');
  }

  Future<File> timesheetFile(PayrollPeriod period) async {
    final dir = await _reportsDir();
    final existing = await findPeriodFile(dir, 'Timesheet', period.fileId);
    return existing ?? File('${dir.path}/Timesheet_${period.fileId}.xlsx');
  }

  Future<bool> filesExist(PayrollPeriod period) async {
    final mileage = await mileageReportFile(period);
    final timesheet = await timesheetFile(period);
    return await mileage.exists() && await timesheet.exists();
  }

  /// Writes [newRate] to [period]'s Mileage Report file (`G1` + Kilometers
  /// row Travel, via `changeMileagePeriodRate`) if that file already
  /// exists -- a no-op otherwise, since a period whose file hasn't been
  /// created yet will pick up the new rate on its own at creation time
  /// (section 6.2's resolve-rate priority rule already handles that case).
  ///
  /// Both rate-change UI paths (Settings default change, the period form's
  /// own rate field) share this exact step -- previously each screen
  /// implemented it independently with near-identical code, risking the
  /// two copies silently diverging on a future fix. The caller is still
  /// responsible for persisting the new rate to [PeriodRepository]
  /// **after** this returns successfully, never before (section 6.2:
  /// "никогда только одно из двух" -- the file must never fail to update
  /// while `period.kmRate` already claims the new value).
  Future<void> writeRateIfFileExists(PayrollPeriod period, double newRate) async {
    final file = await mileageReportFile(period);
    if (await file.exists()) {
      await changeMileagePeriodRate(file, newRate: newRate);
    }
  }

  /// Rewrites [period]'s Mileage Report B3 and Timesheet C2/C6 (section 9:
  /// a Settings employee name/phone change propagates to the current
  /// period's file immediately) for whichever of the two files already
  /// exists -- a no-op for a file that hasn't been created yet, since it
  /// will pick up the current Settings name/phone on its own at creation
  /// time. Mirrors [writeRateIfFileExists]'s existence-gated pattern.
  Future<void> writeHeaderIfFilesExist(
    PayrollPeriod period, {
    required String employeeName,
    required String phone,
  }) async {
    final mileage = await mileageReportFile(period);
    if (await mileage.exists()) {
      await updateMileageEmployeeName(mileage, employeeName: employeeName);
    }
    final timesheet = await timesheetFile(period);
    if (await timesheet.exists()) {
      await updateTimesheetHeader(timesheet, employeeName: employeeName, phone: phone);
    }
  }

  /// Creates both files for [period] from the bundled templates if they
  /// don't already exist (section 5). No-op if they're already there.
  ///
  /// This is the one time the Mileage Report's 5 hidden sheets get healed
  /// (see [createMileagePeriod]) -- they're copied verbatim from the
  /// template right here, so healing them now, once, is enough; every
  /// later write (add receipt/trip/timesheet edit) only heals the visible
  /// sheets, since re-healing potentially large hidden sheets on every
  /// single write was measured to dominate save latency on a real device.
  /// Both files are built inside a spawned isolate (see safe_xlsx_write.dart)
  /// so this doesn't block the UI isolate at app startup either.
  Future<void> ensureFilesExist(PayrollPeriod period, AppSettings settings) async {
    final dir = await _reportsDir();
    final prefix = sanitizedFilenamePrefix(settings.firstName);
    final namePrefix = prefix.isEmpty ? '' : '${prefix}_';

    // Section 5: search first (prefix-agnostic) -- an already-existing file,
    // prefixed or not, must be found and left alone. Only when nothing at
    // all matches do we create a new one, named with *today's* Settings
    // first name (not the combined fullName used for the in-file B3/C2
    // cells -- the filename prefix and the in-file name are separate uses).
    final existingMileage = await findPeriodFile(dir, 'MileageReport', period.fileId);
    if (existingMileage == null) {
      final mileageFile = File('${dir.path}/${namePrefix}MileageReport_${period.fileId}.xlsx');
      await createMileagePeriod(
        mileageFile,
        periodLabel: periodLabel(period),
        employeeName: settings.fullName,
        periodEnd: period.end,
        // Section 6.2, case 1 (file doesn't exist yet): period.kmRate, or
        // the Settings default if this period has none of its own.
        kmRate: period.kmRate ?? settings.kmRate,
      );
    }

    final existingTimesheet = await findPeriodFile(dir, 'Timesheet', period.fileId);
    if (existingTimesheet == null) {
      final timesheetFileHandle = File('${dir.path}/${namePrefix}Timesheet_${period.fileId}.xlsx');
      await createTimesheetPeriod(
        timesheetFileHandle,
        employeeName: settings.fullName,
        periodLabel: periodLabel(period),
        phone: settings.phone,
        period: period,
      );
    }
  }

  /// Periods (from [allPeriods], excluding [currentPeriod]) that fall
  /// outside [retention]'s window relative to [now] -- the pure "which
  /// periods" half of [cleanupAccordingToRetention], split out so the
  /// Settings screen can show an accurate confirmation count *before* the
  /// user commits to narrowing the window (section 11, Пакет 9), without
  /// duplicating the age-check logic.
  List<PayrollPeriod> periodsOutsideRetention({
    required List<PayrollPeriod> allPeriods,
    required PayrollPeriod currentPeriod,
    required RetentionPolicy retention,
    required DateTime now,
  }) {
    final windowDays = retention.windowDays;
    return allPeriods.where((period) {
      if (period.key == currentPeriod.key) return false;
      final ageDays = now.difference(period.end).inDays;
      return windowDays == null || ageDays > windowDays;
    }).toList();
  }

  /// Deletes file pairs for periods outside the retention window relative
  /// to [now], skipping [currentPeriod] entirely (section 11). A `never`
  /// policy (null window) deletes anything that isn't the current period.
  /// Each deleted file's backup (see [BackupManager]) is deleted alongside
  /// it -- otherwise backups of periods the user can no longer even see
  /// would silently accumulate on the phone's storage forever (section 13
  /// п.5's closing requirement; audit 2026-08-18, Пакет 21).
  ///
  /// An ambiguous period (two+ candidate files) is skipped, not resolved by
  /// guessing which one to delete -- this runs unattended at every startup
  /// with no user available to arbitrate, so deleting the wrong file would
  /// be silent, unrecoverable data loss (section 5: "не выбирать наугад").
  Future<void> cleanupAccordingToRetention({
    required List<PayrollPeriod> allPeriods,
    required PayrollPeriod currentPeriod,
    required RetentionPolicy retention,
    required DateTime now,
  }) async {
    final dir = await _reportsDir();
    for (final period in periodsOutsideRetention(
      allPeriods: allPeriods,
      currentPeriod: currentPeriod,
      retention: retention,
      now: now,
    )) {
      try {
        final mileage = await findPeriodFile(dir, 'MileageReport', period.fileId);
        if (mileage != null) await _deleteWithBackup(mileage);
        final timesheet = await findPeriodFile(dir, 'Timesheet', period.fileId);
        if (timesheet != null) await _deleteWithBackup(timesheet);
      } on PeriodFileAmbiguousException {
        continue;
      }
    }
  }

  Future<void> _deleteWithBackup(File file) async {
    await file.delete();
    final backup = await _backupManager.backupFileFor(file);
    if (await backup.exists()) await backup.delete();
  }

  /// Lists periods (from [allPeriods]) that currently have files on disk,
  /// most recent first -- backs the period archive view (section 14).
  Future<List<PayrollPeriod>> listPeriodsWithFiles(List<PayrollPeriod> allPeriods) async {
    final result = <PayrollPeriod>[];
    for (final period in allPeriods) {
      if (await filesExist(period)) result.add(period);
    }
    result.sort((a, b) => b.start.compareTo(a.start));
    return result;
  }

  /// Section 5: finds the file matching `<kind>_<fileId>.xlsx` in [dir],
  /// tolerating any (or no) prefix ending in `_` -- a Settings name change
  /// must never orphan a file created under the old name, and files created
  /// by a pre-update build have no prefix at all. Returns null if none
  /// exist yet. Throws [PeriodFileAmbiguousException] if more than one
  /// candidate matches -- never silently pick one.
  ///
  /// The pattern requires the name to end in exactly `.xlsx`, so it never
  /// matches the atomic-write temp file (`....xlsx.tmp`, section 13 п.8) or
  /// a backup (`....xlsx.bak`) -- though backups already live in a separate
  /// directory ([BackupManager]) and would never actually be passed here.
  ///
  /// `static` and a plain [Directory] (not path_provider) so it's directly
  /// unit-testable, mirroring [BackupManager]'s static-method split between
  /// platform path resolution and plain-`File` logic.
  static Future<File?> findPeriodFile(Directory dir, String kind, String fileId) async {
    final pattern = RegExp('^(.*_)?${RegExp.escape(kind)}_${RegExp.escape(fileId)}\\.xlsx\$');
    final matches = <String>[];
    await for (final entity in dir.list()) {
      if (entity is! File) continue;
      final name = entity.uri.pathSegments.last;
      if (pattern.hasMatch(name)) matches.add(name);
    }
    if (matches.length > 1) {
      throw PeriodFileAmbiguousException(kind, matches);
    }
    if (matches.isEmpty) return null;
    return File('${dir.path}/${matches.single}');
  }

  /// Section 5: sanitizes [name] for use as a filename prefix -- strips
  /// characters illegal in file names plus whitespace, collapsing runs into
  /// a single underscore and trimming the edges. Returns `''` (never a bare
  /// underscore or other placeholder) if nothing meaningful survives -- a
  /// blank or symbols-only Settings name must produce no prefix at all
  /// ("вырожденные имена").
  static String sanitizedFilenamePrefix(String name) {
    final replaced = name.trim().replaceAll(RegExp(r'[/\\:*?"<>|\s]+'), '_');
    final trimmed = replaced.replaceAll(RegExp(r'^_+|_+$'), '');
    return trimmed.replaceAll('_', '').isEmpty ? '' : trimmed;
  }
}
