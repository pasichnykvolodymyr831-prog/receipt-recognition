import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/payroll_period.dart';

/// Owns the locally-writable copy of the payroll period list (section 5):
/// seeded once from the bundled asset, then read/written only from the
/// app's own storage so the user can add periods once the seed runs out.
class PeriodRepository {
  static const _fileName = 'payroll_periods.json';

  Future<File> _localFile() async {
    final dir = await getApplicationDocumentsDirectory();
    return File('${dir.path}/$_fileName');
  }

  Future<List<PayrollPeriod>> loadAll() async {
    final file = await _localFile();
    if (!await file.exists()) {
      final seedJson = await rootBundle.loadString('assets/data/payroll_periods_seed.json');
      final data = jsonDecode(seedJson) as Map<String, dynamic>;
      final periods = (data['periods'] as List<dynamic>)
          .map((e) => PayrollPeriod.fromJson(e as Map<String, dynamic>))
          .toList();
      await _saveAll(periods);
      return periods;
    }
    final content = await file.readAsString();
    final data = jsonDecode(content) as Map<String, dynamic>;
    final periods = (data['periods'] as List<dynamic>)
        .map((e) => PayrollPeriod.fromJson(e as Map<String, dynamic>))
        .toList();
    periods.sort((a, b) => a.start.compareTo(b.start));
    return periods;
  }

  Future<void> _saveAll(List<PayrollPeriod> periods) async {
    final file = await _localFile();
    final sorted = [...periods]..sort((a, b) => a.start.compareTo(b.start));
    final jsonMap = {'periods': sorted.map((e) => e.toJson()).toList()};
    await file.writeAsString(jsonEncode(jsonMap));
  }

  /// Inserts a brand new period. Caller supplies a period built with
  /// `key: PayrollPeriod.newKey()`.
  Future<void> addPeriod(PayrollPeriod period) async {
    final periods = await loadAll();
    periods.add(period);
    await _saveAll(periods);
  }

  /// Updates an existing period matched by [PayrollPeriod.key] (section 5:
  /// "уже добавленный вручную период можно потом снова открыть в этой же
  /// форме и поправить").
  Future<void> updatePeriod(PayrollPeriod period) async {
    final periods = await loadAll();
    final index = periods.indexWhere((p) => p.key == period.key);
    if (index < 0) {
      throw ArgumentError('No period with key ${period.key} found');
    }
    periods[index] = period;
    await _saveAll(periods);
  }

  PayrollPeriod? findCurrent(List<PayrollPeriod> periods, DateTime today) {
    for (final p in periods) {
      if (p.containsDate(today)) return p;
    }
    return null;
  }

  /// Periods strictly after [period], sorted ascending -- used to decide
  /// how many periods remain before the user needs to add more (section 5).
  List<PayrollPeriod> periodsAfter(List<PayrollPeriod> periods, PayrollPeriod period) {
    final after = periods.where((p) => p.start.isAfter(period.end)).toList();
    after.sort((a, b) => a.start.compareTo(b.start));
    return after;
  }

  /// Suggests start/end for the next period, continuing the "9-23" /
  /// "24-end of month" pattern the existing seed follows. Purely a
  /// pre-fill convenience for the add-period form; both fields stay
  /// editable (section 5).
  (DateTime, DateTime) suggestNextPeriodRange(List<PayrollPeriod> periods) {
    if (periods.isEmpty) {
      final now = DateTime.now();
      final start = DateTime(now.year, now.month, 1);
      return (start, DateTime(now.year, now.month, min(23, _daysInMonth(now.year, now.month))));
    }
    final last = periods.reduce((a, b) => a.end.isAfter(b.end) ? a : b);
    final nextStart = last.end.add(const Duration(days: 1));
    DateTime nextEnd;
    if (nextStart.day <= 9) {
      nextEnd = DateTime(nextStart.year, nextStart.month, 23);
    } else {
      final lastDay = _daysInMonth(nextStart.year, nextStart.month);
      nextEnd = DateTime(nextStart.year, nextStart.month, lastDay);
    }
    return (nextStart, nextEnd);
  }
}

int _daysInMonth(int year, int month) {
  final firstOfNextMonth = month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
  return firstOfNextMonth.subtract(const Duration(days: 1)).day;
}
