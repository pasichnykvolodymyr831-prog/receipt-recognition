import 'package:shared_preferences/shared_preferences.dart';

import '../models/payroll_period.dart';
import 'backup_manager.dart';
import 'notification_service.dart';
import 'period_file_manager.dart';
import 'period_repository.dart';
import 'settings_repository.dart';

class BootstrapData {
  final AppSettings settings;
  final List<PayrollPeriod> allPeriods;
  final PayrollPeriod? current;

  const BootstrapData({required this.settings, required this.allPeriods, required this.current});
}

/// Orchestrates the section-5 app-startup sequence: seed/load periods,
/// find today's period, create its files if missing, clean up old files
/// per the retention setting, and schedule the due-date reminder.
class AppStartupService {
  final SettingsRepository settingsRepo;
  final PeriodRepository periodRepo;
  final PeriodFileManager fileManager;
  final NotificationService notificationService;
  final BackupManager backupManager;

  AppStartupService({
    SettingsRepository? settingsRepo,
    PeriodRepository? periodRepo,
    PeriodFileManager? fileManager,
    NotificationService? notificationService,
    BackupManager? backupManager,
  })  : settingsRepo = settingsRepo ?? SettingsRepository(),
        periodRepo = periodRepo ?? PeriodRepository(),
        fileManager = fileManager ?? PeriodFileManager(),
        notificationService = notificationService ?? NotificationService(),
        backupManager = backupManager ?? BackupManager();

  Future<BootstrapData> loadCurrentState() async {
    final settings = await settingsRepo.load();
    final periods = await periodRepo.loadAll();
    final current = periodRepo.findCurrent(periods, DateTime.now());
    return BootstrapData(settings: settings, allPeriods: periods, current: current);
  }

  (DateTime, DateTime) suggestNextPeriodRange(List<PayrollPeriod> periods) =>
      periodRepo.suggestNextPeriodRange(periods);

  /// Creates the current period's files if missing and cleans up old files
  /// per retention. Call once a current period is known (never with a null
  /// period). [onNotificationTap] is wired into the notification plugin's
  /// tap handler on first call only (subsequent calls are a no-op, per
  /// [NotificationService.init]) -- reminder scheduling itself is
  /// [rescheduleAllReminders], called separately since it covers every
  /// period, not just this one.
  Future<void> prepareCurrentPeriod(
    PayrollPeriod period,
    AppSettings settings,
    List<PayrollPeriod> allPeriods, {
    void Function(String? payload)? onNotificationTap,
  }) async {
    // section 13.5: recover from a crash/kill mid-write before touching the files.
    await backupManager.restoreIfCorrupted(await fileManager.mileageReportFile(period));
    await backupManager.restoreIfCorrupted(await fileManager.timesheetFile(period));

    await fileManager.ensureFilesExist(period, settings);
    await fileManager.cleanupAccordingToRetention(
      allPeriods: allPeriods,
      currentPeriod: period,
      retention: settings.retention,
      now: DateTime.now(),
    );
    await notificationService.init(onTap: onNotificationTap);
    await notificationService.requestPermission();
  }

  /// Section 5: "при каждом старте... для периодов с ненаступившим сроком"
  /// -- (re)schedules the due-date reminder for every period whose due date
  /// hasn't passed yet, not just the current one.
  Future<void> rescheduleAllReminders(List<PayrollPeriod> allPeriods) async {
    for (final period in periodRepo.periodsWithFutureDue(allPeriods, DateTime.now())) {
      await notificationService.scheduleDueReminder(period);
    }
  }

  /// Section 5: once 2 or fewer periods remain after the current one, show
  /// a one-time reminder to add more -- but only once per period (tracked
  /// by the current period's stable key so it doesn't repeat every launch).
  Future<bool> shouldShowLowPeriodsReminder(List<PayrollPeriod> allPeriods, PayrollPeriod current) async {
    final after = periodRepo.periodsAfter(allPeriods, current);
    if (after.length > 2) return false;

    final prefs = await SharedPreferences.getInstance();
    const key = 'lowPeriodsReminder.lastShownForKey';
    if (prefs.getString(key) == current.key) return false;
    await prefs.setString(key, current.key);
    return true;
  }
}
