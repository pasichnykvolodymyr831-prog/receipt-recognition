import 'package:flutter_local_notifications/flutter_local_notifications.dart';
import 'package:timezone/data/latest_all.dart' as tz_data;
import 'package:timezone/timezone.dart' as tz;

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';

/// Wraps flutter_local_notifications for the section-5 "due date - 2 days"
/// submission reminder. Uses an inexact Android alarm, so it only needs the
/// plain POST_NOTIFICATIONS permission (Android 13+), not the sensitive
/// exact-alarm permission.
class NotificationService {
  final _plugin = FlutterLocalNotificationsPlugin();
  bool _initialized = false;

  Future<void> init({void Function(String? payload)? onTap}) async {
    if (_initialized) return;
    tz_data.initializeTimeZones();
    try {
      tz.setLocalLocation(tz.getLocation('America/Edmonton'));
    } catch (_) {
      // Falls back to UTC if the timezone database entry is unavailable;
      // only shifts the reminder by a few hours, not days.
    }

    const androidSettings = AndroidInitializationSettings('@mipmap/ic_launcher');
    const iosSettings = DarwinInitializationSettings();
    const settings = InitializationSettings(android: androidSettings, iOS: iosSettings);

    await _plugin.initialize(
      settings: settings,
      onDidReceiveNotificationResponse: (response) => onTap?.call(response.payload),
    );
    _initialized = true;
  }

  Future<void> requestPermission() async {
    await _plugin
        .resolvePlatformSpecificImplementation<AndroidFlutterLocalNotificationsPlugin>()
        ?.requestNotificationsPermission();
  }

  // The epoch (2020-01-01) is arbitrary -- just a fixed point safely before
  // any realistic period start date, chosen to keep the resulting id small
  // (flutter_local_notifications' id is a 32-bit int). Collision-safe by
  // construction: periods are sequential, non-overlapping date ranges, so
  // any two periods always have different `start` dates and therefore
  // different day-counts here (Пакет 39, audit 2026-08-18).
  int _idFor(PayrollPeriod period) => period.start.difference(DateTime(2020, 1, 1)).inDays;

  /// Schedules the "due - 2 days" reminder for [period]. Safe to call on
  /// every app start / period detection -- re-scheduling with the same id
  /// replaces any previous reminder for this period. Uses [period.due], not
  /// [PayrollPeriod.weekendAltDue] (section 5).
  ///
  /// The body text depends on which half of a Mileage cycle [period] is
  /// (whimsical-booping-salamander.md, Пакет 6): a "24-8" (cycle-opening)
  /// period's own due date is only ever a Timesheet deadline -- accounting
  /// accepts the Mileage Report only every 4 weeks (see `MileageCycle`), so
  /// it isn't due yet for this specific period. A "9-23" (closing) period's
  /// due date IS the whole cycle's due (`MileageCycle.due` reads
  /// `secondHalf.due`), so both are due together.
  Future<void> scheduleDueReminder(PayrollPeriod period, {required String languageCode}) async {
    final fireAt = period.due.subtract(const Duration(days: 2));
    if (fireAt.isBefore(DateTime.now())) return;

    const details = NotificationDetails(
      android: AndroidNotificationDetails(
        'due_reminders',
        'Submission reminders',
        channelDescription: 'Reminds you 2 days before the Mileage Report / Timesheet are due',
        importance: Importance.defaultImportance,
      ),
      iOS: DarwinNotificationDetails(),
    );

    final bodyKey =
        period.start.day >= 24 ? 'notification.dueReminderTimesheetOnly' : 'notification.dueReminderBoth';

    await _plugin.zonedSchedule(
      id: _idFor(period),
      scheduledDate: tz.TZDateTime.from(fireAt, tz.local),
      title: 'ExpenseFlow',
      body: tForLanguage(languageCode, bodyKey),
      notificationDetails: details,
      androidScheduleMode: AndroidScheduleMode.inexact,
      payload: period.fileId,
    );
  }
}
