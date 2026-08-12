import 'dart:math';

final _rng = Random();

class StatHoliday {
  final String name;
  final DateTime date;

  const StatHoliday({required this.name, required this.date});

  factory StatHoliday.fromJson(Map<String, dynamic> json) {
    return StatHoliday(
      name: json['name'] as String,
      date: DateTime.parse(json['date'] as String),
    );
  }

  Map<String, dynamic> toJson() => {
        'name': name,
        'date': _dateOnly(date),
      };

  bool isSameDay(DateTime other) =>
      date.year == other.year && date.month == other.month && date.day == other.day;
}

class PayrollPeriod {
  /// Stable identifier that survives edits to start/end (section 5: a
  /// manually-added period can be reopened and its dates corrected later).
  /// Distinct from [fileId], which is derived from start/end and is what
  /// changes if those dates are edited.
  final String key;
  final DateTime start;
  final DateTime end;
  final DateTime due;
  final DateTime? weekendAltDue;
  final List<StatHoliday> statHolidays;

  const PayrollPeriod({
    required this.key,
    required this.start,
    required this.end,
    required this.due,
    this.weekendAltDue,
    this.statHolidays = const [],
  });

  /// Identifier used for xlsx file naming (section 5): `<start>_<end>`.
  String get fileId => '${_dateOnly(start)}_${_dateOnly(end)}';

  /// Generates a fresh, unique [key] for a manually-added period.
  static String newKey() =>
      'p_${DateTime.now().microsecondsSinceEpoch}_${_rng.nextInt(1 << 32)}';

  factory PayrollPeriod.fromJson(Map<String, dynamic> json) {
    final start = DateTime.parse(json['start'] as String);
    final end = DateTime.parse(json['end'] as String);
    return PayrollPeriod(
      key: json['key'] as String? ?? '${_dateOnly(start)}_${_dateOnly(end)}',
      start: start,
      end: end,
      due: DateTime.parse(json['due'] as String),
      weekendAltDue: json['weekend_alt_due'] != null
          ? DateTime.parse(json['weekend_alt_due'] as String)
          : null,
      statHolidays: (json['stat_holidays'] as List<dynamic>? ?? [])
          .map((e) => StatHoliday.fromJson(e as Map<String, dynamic>))
          .toList(),
    );
  }

  Map<String, dynamic> toJson() => {
        'key': key,
        'start': _dateOnly(start),
        'end': _dateOnly(end),
        'due': due.toIso8601String(),
        'weekend_alt_due': weekendAltDue?.toIso8601String(),
        'stat_holidays': statHolidays.map((e) => e.toJson()).toList(),
      };

  bool containsDate(DateTime date) {
    final d = DateTime(date.year, date.month, date.day);
    final s = DateTime(start.year, start.month, start.day);
    final e = DateTime(end.year, end.month, end.day);
    return !d.isBefore(s) && !d.isAfter(e);
  }

  bool isStatHoliday(DateTime date) {
    return statHolidays.any((h) => h.isSameDay(date));
  }

  PayrollPeriod copyWith({
    DateTime? start,
    DateTime? end,
    DateTime? due,
    DateTime? weekendAltDue,
    bool clearWeekendAltDue = false,
    List<StatHoliday>? statHolidays,
  }) {
    return PayrollPeriod(
      key: key,
      start: start ?? this.start,
      end: end ?? this.end,
      due: due ?? this.due,
      weekendAltDue:
          clearWeekendAltDue ? null : (weekendAltDue ?? this.weekendAltDue),
      statHolidays: statHolidays ?? this.statHolidays,
    );
  }
}

String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
