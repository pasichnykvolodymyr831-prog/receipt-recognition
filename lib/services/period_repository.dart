import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:flutter/services.dart' show rootBundle;
import 'package:path_provider/path_provider.dart';

import '../models/mileage_cycle.dart';
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

  /// Periods whose [PayrollPeriod.due] hasn't passed [now] yet (section 5:
  /// "при каждом старте... для периодов с ненаступившим сроком") -- used to
  /// decide which periods still need their due-date reminder (re)scheduled,
  /// not just the current one.
  List<PayrollPeriod> periodsWithFutureDue(List<PayrollPeriod> periods, DateTime now) =>
      periods.where((p) => p.due.isAfter(now)).toList();

  /// Periods (from [periods], excluding [current]) that ended before
  /// [current] started, sorted descending by [PayrollPeriod.start] (most
  /// recent first) -- backs the period archive view (section 5/14, Пакет
  /// 10). Deliberately relative to [current]'s own start, not wall-clock
  /// `DateTime.now()` -- consistent with how [findCurrent] and
  /// [periodsAfter] already reason about period ordering, so a period is
  /// "past" the same way everywhere in the app, not by two different
  /// definitions depending on which screen asks.
  List<PayrollPeriod> pastPeriods(List<PayrollPeriod> periods, PayrollPeriod current) {
    final past = periods.where((p) => p.key != current.key && p.end.isBefore(current.start)).toList();
    past.sort((a, b) => b.start.compareTo(a.start));
    return past;
  }

  /// Finds the period whose [PayrollPeriod.fileId] matches [fileId] --
  /// resolves a due-date reminder notification's payload back to a period
  /// (section 5: tapping the reminder opens that period).
  PayrollPeriod? findByFileId(List<PayrollPeriod> periods, String fileId) {
    for (final p in periods) {
      if (p.fileId == fileId) return p;
    }
    return null;
  }

  /// Pairs up consecutive periods into 4-week Mileage cycles (accounting
  /// accepts Mileage Report every 4 weeks, Timesheet stays every 2 weeks --
  /// see `whimsical-booping-salamander.md`). A "24th-8th" period (`start.day
  /// >= 24`) pairs with the very next period in start order only if that
  /// period is a genuine "9th-23rd" shape (`start.day < 24`) AND starts
  /// exactly the day after the first half ends -- not merely "next in the
  /// list", so a gap in manually-edited periods never silently glues two
  /// unrelated periods into one cycle. Either half without a matching
  /// partner (the real orphan case in the seed data: the very first period,
  /// 2026-03-09..23, has no preceding "24-8" half) simply doesn't produce a
  /// cycle -- no Mileage file is created for it until the pair is complete.
  List<MileageCycle> mileageCycles(List<PayrollPeriod> periods) {
    final sorted = [...periods]..sort((a, b) => a.start.compareTo(b.start));
    final cycles = <MileageCycle>[];
    for (var i = 0; i < sorted.length; i++) {
      final first = sorted[i];
      if (first.start.day < 24) continue;
      if (i + 1 >= sorted.length) continue;
      final second = sorted[i + 1];
      if (second.start.day >= 24) continue;
      if (!_isNextDay(first.end, second.start)) continue;
      cycles.add(MileageCycle(firstHalf: first, secondHalf: second));
    }
    return cycles;
  }

  /// The Mileage cycle [period] belongs to (as either half), or `null` if
  /// [period] is currently orphaned (its partner half hasn't been added
  /// yet).
  MileageCycle? mileageCycleFor(PayrollPeriod period, List<PayrollPeriod> periods) {
    for (final cycle in mileageCycles(periods)) {
      if (cycle.firstHalf.key == period.key || cycle.secondHalf.key == period.key) {
        return cycle;
      }
    }
    return null;
  }

  /// Cycles (from [mileageCycles]) that ended before the reference point --
  /// [currentCycle]'s own start if known, otherwise [currentPeriod]'s own
  /// start as a fallback for when the calendar-current period is itself
  /// orphaned (whimsical-booping-salamander.md, Пакет 8a: the archive must
  /// still render sensibly rather than crash or show nothing). Excludes
  /// [currentCycle] itself by `fileId`, sorted descending by start (most
  /// recent first) -- mirrors [pastPeriods]' relative-to-current style.
  List<MileageCycle> pastMileageCycles(
    List<PayrollPeriod> allPeriods,
    PayrollPeriod currentPeriod,
    MileageCycle? currentCycle,
  ) {
    final referenceStart = currentCycle?.start ?? currentPeriod.start;
    final past = mileageCycles(allPeriods)
        .where((c) => (currentCycle == null || c.fileId != currentCycle.fileId) && c.end.isBefore(referenceStart))
        .toList();
    past.sort((a, b) => b.start.compareTo(a.start));
    return past;
  }

  /// Past periods (per [pastPeriods]) that don't belong to any Mileage
  /// cycle -- e.g. the very first period ever recorded, which can never
  /// have a preceding "24-8" half to pair with. [pastMileageCycles] alone
  /// can't represent these (they're not cycles), so they'd otherwise
  /// silently vanish from the archive entirely -- exactly the "не пропадать
  /// молча" failure mode section 5/14 (Пакет 10) already guards against
  /// elsewhere (whimsical-booping-salamander.md, Пакет 8a).
  List<PayrollPeriod> pastOrphanedPeriods(List<PayrollPeriod> allPeriods, PayrollPeriod currentPeriod) {
    final paired = <String>{};
    for (final cycle in mileageCycles(allPeriods)) {
      paired.add(cycle.firstHalf.key);
      paired.add(cycle.secondHalf.key);
    }
    return pastPeriods(allPeriods, currentPeriod).where((p) => !paired.contains(p.key)).toList();
  }

  /// Suggests start/end for the next period, continuing the "9-23" /
  /// "24-8th of next month" pattern the existing seed follows (e.g.
  /// 2026-07-24 to 2026-08-08). Purely a pre-fill convenience for the
  /// add-period form; both fields stay editable (section 5).
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
      // A period starting on/after the 24th always ends on the 8th of the
      // following month (not the end of its own month) -- DateTime
      // normalizes month=13 into January of next year automatically.
      nextEnd = DateTime(nextStart.year, nextStart.month + 1, 8);
    }
    return (nextStart, nextEnd);
  }
}

bool _isNextDay(DateTime end, DateTime start) {
  final e = DateTime(end.year, end.month, end.day);
  final s = DateTime(start.year, start.month, start.day);
  return s.difference(e).inDays == 1;
}

int _daysInMonth(int year, int month) {
  final firstOfNextMonth = month == 12 ? DateTime(year + 1, 1, 1) : DateTime(year, month + 1, 1);
  return firstOfNextMonth.subtract(const Duration(days: 1)).day;
}
