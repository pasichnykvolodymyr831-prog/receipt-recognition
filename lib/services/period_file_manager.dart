import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/mileage_cycle.dart';
import '../models/payroll_period.dart';
import 'backup_manager.dart';
import 'safe_xlsx_write.dart';
import 'settings_repository.dart';

String periodLabel(PayrollPeriod period) {
  String fmt(DateTime d) => '${_month(d.month)} ${d.day}';
  return '${fmt(period.start)} - ${fmt(period.end)}, ${period.end.year}';
}

/// Same shape as [periodLabel], for a [MileageCycle] spanning both its
/// halves -- the Mileage Report's own period-label cell now covers the
/// whole 4-week cycle (section 6.2/13 п.1а), not just one 2-week period.
String cycleLabel(MileageCycle cycle) {
  String fmt(DateTime d) => '${_month(d.month)} ${d.day}';
  return '${fmt(cycle.start)} - ${fmt(cycle.end)}, ${cycle.end.year}';
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

/// Creates, locates, and cleans up the per-period/per-cycle xlsx files
/// (section 5) in a flat `reports/` folder under the app's documents
/// directory. File names already encode the period/cycle range, so no
/// per-period subfolder is needed:
/// `<prefix_>MileageReport_<cycleStart>_<cycleEnd>.xlsx` (one file per
/// 4-week Mileage cycle -- accounting only accepts Mileage Report every 4
/// weeks, see `MileageCycle`), `<prefix_>Timesheet_<start>_<end>.xlsx` (one
/// file per 2-week period, unchanged), where `<prefix_>` is the sanitized
/// Settings first name at the time of creation, or nothing.
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

  Future<File> mileageReportFile(MileageCycle cycle) async {
    final dir = await _reportsDir();
    final existing = await findPeriodFile(dir, 'MileageReport', cycle.fileId);
    return existing ?? File('${dir.path}/MileageReport_${cycle.fileId}.xlsx');
  }

  Future<File> timesheetFile(PayrollPeriod period) async {
    final dir = await _reportsDir();
    final existing = await findPeriodFile(dir, 'Timesheet', period.fileId);
    return existing ?? File('${dir.path}/Timesheet_${period.fileId}.xlsx');
  }

  /// Rewrites [period]'s Timesheet C2/C6, and (when [cycle] is known) its
  /// Mileage cycle's B3 (section 9: a Settings employee name/phone change
  /// propagates to the current period's file immediately) -- a no-op for a
  /// file that hasn't been created yet, since it will pick up the current
  /// Settings name/phone on its own at creation time.
  Future<void> writeHeaderIfFilesExist(
    PayrollPeriod period, {
    MileageCycle? cycle,
    required String employeeName,
    required String phone,
  }) async {
    if (cycle != null) {
      final mileage = await mileageReportFile(cycle);
      if (await mileage.exists()) {
        await updateMileageEmployeeName(mileage, employeeName: employeeName);
      }
    }
    final timesheet = await timesheetFile(period);
    if (await timesheet.exists()) {
      await updateTimesheetHeader(timesheet, employeeName: employeeName, phone: phone);
    }
  }

  /// Creates [period]'s Timesheet file from the bundled template if it
  /// doesn't already exist (section 5). No-op if it's already there.
  Future<void> ensureTimesheetFileExists(PayrollPeriod period, AppSettings settings) async {
    final dir = await _reportsDir();
    final prefix = sanitizedFilenamePrefix(settings.firstName);
    final namePrefix = prefix.isEmpty ? '' : '${prefix}_';

    // Section 5: search first (prefix-agnostic) -- an already-existing file,
    // prefixed or not, must be found and left alone. Only when nothing at
    // all matches do we create a new one, named with *today's* Settings
    // first name (not the combined fullName used for the in-file C2 cell --
    // the filename prefix and the in-file name are separate uses).
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

  /// Creates [cycle]'s Mileage Report file from the bundled template if it
  /// doesn't already exist (accounting accepts Mileage Report only every 4
  /// weeks -- one file per cycle, not per 2-week period). No-op if it's
  /// already there.
  ///
  /// This is the one time the Mileage Report's 5 hidden sheets get healed
  /// (see [createMileagePeriod]) -- they're copied verbatim from the
  /// template right here, so healing them now, once, is enough; every
  /// later write (add receipt/trip) only heals the visible sheets, since
  /// re-healing potentially large hidden sheets on every single write was
  /// measured to dominate save latency on a real device. Built inside a
  /// spawned isolate (see safe_xlsx_write.dart) so this doesn't block the
  /// UI isolate at app startup either.
  Future<void> ensureMileageFileExists(MileageCycle cycle, AppSettings settings) async {
    final dir = await _reportsDir();
    final prefix = sanitizedFilenamePrefix(settings.firstName);
    final namePrefix = prefix.isEmpty ? '' : '${prefix}_';

    final existingMileage = await findPeriodFile(dir, 'MileageReport', cycle.fileId);
    if (existingMileage != null) return;

    if (await _migrateLegacyMileageFile(dir, cycle, namePrefix)) return;

    final mileageFile = File('${dir.path}/${namePrefix}MileageReport_${cycle.fileId}.xlsx');
    await createMileagePeriod(
      mileageFile,
      periodLabel: cycleLabel(cycle),
      employeeName: settings.fullName,
      // The Kilometers row's date must reflect the end of the WHOLE
      // cycle, not just the opening half (section 6.2/13 п.1а).
      periodEnd: cycle.end,
      // Section 6.2, case 1 (file doesn't exist yet): the cycle's own
      // rate (fixed on its opening half), or the Settings default if
      // neither half of the cycle has one of its own.
      kmRate: cycle.kmRate ?? settings.kmRate,
    );
  }

  /// One-time migration for a Mileage Report file created by a pre-cycle
  /// build (whimsical-booping-salamander.md): before this feature, a
  /// Mileage file was keyed by a single 2-week [PayrollPeriod.fileId], the
  /// same as Timesheet still is today. A user with real data from before
  /// this update has such a file sitting under [cycle.firstHalf.fileId] or
  /// [cycle.secondHalf.fileId] -- renaming it in place (real receipts/trips
  /// preserved untouched) is the only safe option; creating a fresh blank
  /// file under the new cycle-keyed name would silently orphan the old one
  /// and make the user's real entries invisible in the app (section 5:
  /// "не выбирать наугад" -- the same principle [PeriodFileAmbiguousException]
  /// already enforces elsewhere). Returns `true` if a migration happened
  /// (nothing left to do), `false` if there was nothing to migrate.
  Future<bool> _migrateLegacyMileageFile(Directory dir, MileageCycle cycle, String namePrefix) async {
    final legacyFirstHalf = await findPeriodFile(dir, 'MileageReport', cycle.firstHalf.fileId);
    final legacySecondHalf = await findPeriodFile(dir, 'MileageReport', cycle.secondHalf.fileId);
    if (legacyFirstHalf != null && legacySecondHalf != null && legacyFirstHalf.path != legacySecondHalf.path) {
      // Both halves independently have their own pre-update Mileage file --
      // can't safely pick one to keep and one to discard.
      throw PeriodFileAmbiguousException(
          'MileageReport', [legacyFirstHalf.uri.pathSegments.last, legacySecondHalf.uri.pathSegments.last]);
    }
    final legacy = legacyFirstHalf ?? legacySecondHalf;
    if (legacy == null) return false;

    final migratedFile = File('${dir.path}/${namePrefix}MileageReport_${cycle.fileId}.xlsx');
    await legacy.rename(migratedFile.path);

    // Best-effort: carry the file's own backup along under the new name too
    // (section 13 п.5), so the next write's backupBeforeWrite doesn't leave
    // a stale, permanently-orphaned .bak sitting under the old filename.
    final oldBackup = await _backupManager.backupFileFor(legacy);
    if (await oldBackup.exists()) {
      final newBackup = await _backupManager.backupFileFor(migratedFile);
      await oldBackup.rename(newBackup.path);
    }
    return true;
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
  ///
  /// Still keyed off each 2-week [PayrollPeriod]'s own `fileId` for both
  /// file kinds -- correct for Timesheet as-is, but only an approximation
  /// for Mileage now that its files are cycle-keyed; a period-level
  /// retention pass can delete a Mileage file that's still live for the
  /// other half of its cycle. Left as the pre-existing behavior here
  /// deliberately -- reworking this onto cycles is Пакет 7 of
  /// `whimsical-booping-salamander.md`, which needs its own
  /// regression test written first (a real data-loss risk this method
  /// doesn't yet guard against).
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
