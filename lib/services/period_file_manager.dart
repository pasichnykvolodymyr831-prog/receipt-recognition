import 'dart:io';

import 'package:path_provider/path_provider.dart';

import '../models/payroll_period.dart';
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

/// Creates, locates, and cleans up the per-period xlsx files (section 5)
/// in a flat `reports/` folder under the app's documents directory. File
/// names already encode the period range, so no per-period subfolder is
/// needed: `MileageReport_<start>_<end>.xlsx`, `Timesheet_<start>_<end>.xlsx`.
class PeriodFileManager {
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
    return File('${dir.path}/MileageReport_${period.fileId}.xlsx');
  }

  Future<File> timesheetFile(PayrollPeriod period) async {
    final dir = await _reportsDir();
    return File('${dir.path}/Timesheet_${period.fileId}.xlsx');
  }

  Future<bool> filesExist(PayrollPeriod period) async {
    final mileage = await mileageReportFile(period);
    final timesheet = await timesheetFile(period);
    return await mileage.exists() && await timesheet.exists();
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
    final mileageFile = await mileageReportFile(period);
    if (!await mileageFile.exists()) {
      await createMileagePeriod(
        mileageFile,
        periodLabel: periodLabel(period),
        employeeName: settings.fullName,
        periodEnd: period.end,
      );
    }

    final timesheetFileHandle = await timesheetFile(period);
    if (!await timesheetFileHandle.exists()) {
      await createTimesheetPeriod(
        timesheetFileHandle,
        employeeName: settings.fullName,
        periodLabel: periodLabel(period),
        phone: settings.phone,
        period: period,
      );
    }
  }

  /// Deletes file pairs for periods outside the retention window relative
  /// to [now], skipping [currentPeriod] entirely (section 11). A `never`
  /// policy (null window) deletes anything that isn't the current period.
  Future<void> cleanupAccordingToRetention({
    required List<PayrollPeriod> allPeriods,
    required PayrollPeriod currentPeriod,
    required RetentionPolicy retention,
    required DateTime now,
  }) async {
    final windowDays = retention.windowDays;
    for (final period in allPeriods) {
      if (period.key == currentPeriod.key) continue;
      final ageDays = now.difference(period.end).inDays;
      final shouldDelete = windowDays == null || ageDays > windowDays;
      if (!shouldDelete) continue;

      final mileage = await mileageReportFile(period);
      final timesheet = await timesheetFile(period);
      if (await mileage.exists()) await mileage.delete();
      if (await timesheet.exists()) await timesheet.delete();
    }
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
}
