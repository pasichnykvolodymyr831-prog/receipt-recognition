import 'package:flutter/material.dart';

/// Formats a [DateTime] as `YYYY-MM-DD` -- the app's one canonical date
/// display format (Excel cells hold real `DateTime`/`DateCellValue` values,
/// not this string; this is purely for on-screen text). Previously
/// reimplemented independently across several screens (Пакет 32, audit
/// 2026-08-18) -- always use this instead of repeating the padLeft calls.
String formatDate(DateTime d) =>
    '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

/// Formats a [TimeOfDay] as `{h}{mm if not :00}{am|pm}`, e.g. 8:00 -> "8am",
/// 16:30 -> "430pm", 9:15 -> "915am". Matches the Timesheet template's
/// existing text convention for Start Time / Finish Time (section 6.3).
String formatClockTime(TimeOfDay time) {
  final hour12 = time.hourOfPeriod == 0 ? 12 : time.hourOfPeriod;
  final suffix = time.period == DayPeriod.am ? 'am' : 'pm';
  final minutePart = time.minute == 0 ? '' : time.minute.toString().padLeft(2, '0');
  return '$hour12$minutePart$suffix';
}

/// Formats a [start]-[end] range as `{HHMM}-{HHMM}` 24h, no colons, e.g.
/// 12:00-12:30 -> "1200-1230". Matches Lunch Break / Coffee Break columns.
String formatTimeRange(TimeOfDay start, TimeOfDay end) {
  String hhmm(TimeOfDay t) =>
      '${t.hour.toString().padLeft(2, '0')}${t.minute.toString().padLeft(2, '0')}';
  return '${hhmm(start)}-${hhmm(end)}';
}

/// Parses a range string produced by [formatTimeRange] back into two
/// [TimeOfDay] values, or null if the text doesn't match the expected shape.
(TimeOfDay, TimeOfDay)? parseTimeRange(String text) {
  final match = RegExp(r'^(\d{2})(\d{2})-(\d{2})(\d{2})$').firstMatch(text.trim());
  if (match == null) return null;
  final startHour = int.parse(match.group(1)!);
  final startMinute = int.parse(match.group(2)!);
  final endHour = int.parse(match.group(3)!);
  final endMinute = int.parse(match.group(4)!);
  if (startHour > 23 || endHour > 23 || startMinute > 59 || endMinute > 59) {
    return null;
  }
  return (
    TimeOfDay(hour: startHour, minute: startMinute),
    TimeOfDay(hour: endHour, minute: endMinute),
  );
}

/// Parses a clock-time string produced by [formatClockTime] back into a
/// [TimeOfDay], or null if the text doesn't match the expected shape.
TimeOfDay? parseClockTime(String text) {
  final match =
      RegExp(r'^(\d{1,2})(\d{2})?(am|pm)$', caseSensitive: false).firstMatch(text.trim());
  if (match == null) return null;
  var hour = int.parse(match.group(1)!);
  final minute = match.group(2) != null ? int.parse(match.group(2)!) : 0;
  final isPm = match.group(3)!.toLowerCase() == 'pm';
  if (hour < 1 || hour > 12 || minute > 59) return null;
  hour = hour % 12;
  if (isPm) hour += 12;
  return TimeOfDay(hour: hour, minute: minute);
}

/// Duration in decimal hours between two [TimeOfDay] values on the same day.
double hoursBetween(TimeOfDay start, TimeOfDay end) {
  final startMinutes = start.hour * 60 + start.minute;
  final endMinutes = end.hour * 60 + end.minute;
  return (endMinutes - startMinutes) / 60.0;
}
