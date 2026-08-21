import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/services/period_repository.dart';

PayrollPeriod _period(String start, String end, {double? kmRate}) => PayrollPeriod(
      key: '$start-$end',
      start: DateTime.parse(start),
      end: DateTime.parse(end),
      due: DateTime.parse(end),
      kmRate: kmRate,
    );

void main() {
  group('suggestNextPeriodRange (section 5: "9-23" / "24-8th of next month" pattern)', () {
    test('a period ending on the 8th (started on the 24th) is followed by 9th-23rd, same month', () {
      final repo = PeriodRepository();
      final (start, end) = repo.suggestNextPeriodRange([_period('2026-07-24', '2026-08-08')]);

      expect(start, DateTime(2026, 8, 9));
      expect(end, DateTime(2026, 8, 23));
    });

    test('a period ending on the 23rd is followed by 24th-8th of the NEXT month, not end of the current month', () {
      final repo = PeriodRepository();
      final (start, end) = repo.suggestNextPeriodRange([_period('2026-08-09', '2026-08-23')]);

      expect(start, DateTime(2026, 8, 24));
      expect(end, DateTime(2026, 9, 8),
          reason: 'regression test: this used to wrongly compute end-of-August instead of Sept 8');
    });

    test('the 24th-8th rollover crosses a year boundary correctly (December -> January)', () {
      final repo = PeriodRepository();
      final (start, end) = repo.suggestNextPeriodRange([_period('2026-11-09', '2026-11-23')]);

      expect(start, DateTime(2026, 11, 24));
      expect(end, DateTime(2026, 12, 8));
    });

    test('a period ending on the 23rd of December rolls into January of the next year', () {
      final repo = PeriodRepository();
      final (start, end) = repo.suggestNextPeriodRange([_period('2026-12-09', '2026-12-23')]);

      expect(start, DateTime(2026, 12, 24));
      expect(end, DateTime(2027, 1, 8));
    });

    test('picks the latest-ending period among several when computing the next range', () {
      final repo = PeriodRepository();
      final (start, end) = repo.suggestNextPeriodRange([
        _period('2026-07-09', '2026-07-23'),
        _period('2026-07-24', '2026-08-08'),
        _period('2026-06-24', '2026-07-08'),
      ]);

      expect(start, DateTime(2026, 8, 9));
      expect(end, DateTime(2026, 8, 23));
    });
  });

  group('periodsWithFutureDue (Пакет 8: reschedule reminders for every period, not just current)', () {
    test('keeps only periods whose due date is still ahead of now', () {
      final repo = PeriodRepository();
      final past = _period('2026-06-09', '2026-06-23');
      final futureA = _period('2026-08-09', '2026-08-23');
      final futureB = _period('2026-08-24', '2026-09-08');
      final now = DateTime(2026, 8, 1);

      final result = repo.periodsWithFutureDue([past, futureA, futureB], now);

      expect(result, [futureA, futureB]);
    });

    test('a period whose due date is exactly now is excluded', () {
      final repo = PeriodRepository();
      final period = _period('2026-08-09', '2026-08-23');

      expect(repo.periodsWithFutureDue([period], period.due), isEmpty);
    });
  });

  group('pastPeriods (Пакет 10, code-review 2026-08-19: extracted from period_archive_screen.dart '
      'for the same reason as periodsAfter/periodsWithFutureDue -- a named, independently-testable filter)', () {
    test('keeps periods that ended before the current period started, excludes the current one', () {
      final repo = PeriodRepository();
      final past = _period('2026-07-09', '2026-07-23');
      final current = _period('2026-08-09', '2026-08-23');

      final result = repo.pastPeriods([past, current], current);

      expect(result, [past]);
    });

    test('sorts results descending by start (most recent first)', () {
      final repo = PeriodRepository();
      final oldest = _period('2026-06-09', '2026-06-23');
      final middle = _period('2026-06-24', '2026-07-08');
      final newest = _period('2026-07-09', '2026-07-23');
      final current = _period('2026-08-09', '2026-08-23');

      final result = repo.pastPeriods([middle, oldest, newest], current);

      expect(result, [newest, middle, oldest]);
    });

    test('a period is past relative to the current period\'s own start, not wall-clock DateTime.now() -- '
        'regression test for the pre-extraction inline filter which reasoned the same way, now proven '
        'independent of when the test actually runs', () {
      final repo = PeriodRepository();
      // "current" is set far in the future relative to the real clock --
      // if pastPeriods secretly compared against DateTime.now() instead of
      // current.start, this period (which ends after any realistic "now"
      // but well before current.start) would wrongly be excluded.
      final period = _period('2030-01-09', '2030-01-23');
      final currentFarAhead = _period('2031-08-09', '2031-08-23');

      expect(repo.pastPeriods([period, currentFarAhead], currentFarAhead), [period]);
    });

    test('a period ending exactly on the current period\'s start is not past (not strictly before)', () {
      final repo = PeriodRepository();
      final current = _period('2026-08-09', '2026-08-23');
      final adjacent = PayrollPeriod(
        key: 'adjacent',
        start: DateTime(2026, 7, 24),
        end: current.start,
        due: current.start,
      );

      expect(repo.pastPeriods([adjacent, current], current), isEmpty);
    });

    test('empty when there are no periods before the current one', () {
      final repo = PeriodRepository();
      final current = _period('2026-08-09', '2026-08-23');
      final future = _period('2026-08-24', '2026-09-08');

      expect(repo.pastPeriods([current, future], current), isEmpty);
    });
  });

  group('mileageCycles / mileageCycleFor (Пакет 1 of the 4-week Mileage-cycle plan, '
      'whimsical-booping-salamander.md: pairing consecutive periods into one Mileage cycle)', () {
    test('pairs a "24-8" period with the very next "9-23" period', () {
      final repo = PeriodRepository();
      final first = _period('2026-07-24', '2026-08-08', kmRate: 0.6);
      final second = _period('2026-08-09', '2026-08-23');

      final cycles = repo.mileageCycles([first, second]);

      expect(cycles, hasLength(1));
      expect(cycles.single.firstHalf, first);
      expect(cycles.single.secondHalf, second);
      expect(cycles.single.start, DateTime(2026, 7, 24));
      expect(cycles.single.end, DateTime(2026, 8, 23));
      expect(cycles.single.due, second.due);
      expect(cycles.single.fileId, '2026-07-24_2026-08-23');
      expect(cycles.single.kmRate, 0.6, reason: 'the cycle rate lives on the opening (firstHalf) period');
    });

    test('pairs correctly across a month/year boundary (December -> January)', () {
      final repo = PeriodRepository();
      final first = _period('2026-12-24', '2027-01-08');
      final second = _period('2027-01-09', '2027-01-23');

      final cycles = repo.mileageCycles([first, second]);

      expect(cycles, hasLength(1));
      expect(cycles.single.end, DateTime(2027, 1, 23));
    });

    test('the real orphaned case from the seed data: the very first period (2026-03-09..23) '
        'has no preceding "24-8" half and forms no cycle', () {
      final repo = PeriodRepository();
      final onlyPeriod = _period('2026-03-09', '2026-03-23');

      expect(repo.mileageCycles([onlyPeriod]), isEmpty);
      expect(repo.mileageCycleFor(onlyPeriod, [onlyPeriod]), isNull);
    });

    test('a "24-8" period whose "9-23" partner hasn\'t been added yet forms no cycle', () {
      final repo = PeriodRepository();
      final opening = _period('2026-07-24', '2026-08-08');

      expect(repo.mileageCycles([opening]), isEmpty);
      expect(repo.mileageCycleFor(opening, [opening]), isNull);
    });

    test('a gap between two otherwise correctly-shaped periods does NOT pair them '
        '(regression test: adjacency is checked by actual date, not merely "next in the sorted list")', () {
      final repo = PeriodRepository();
      final opening = _period('2026-07-24', '2026-08-08');
      // Missing 2026-08-09..23 entirely -- next entry in start order is the
      // FOLLOWING cycle's opening half, not a genuine "9-23" second half.
      final unrelatedLater = _period('2026-09-24', '2026-10-08');

      final cycles = repo.mileageCycles([opening, unrelatedLater]);

      expect(cycles, isEmpty);
    });

    test('mileageCycleFor resolves via either half of the pair', () {
      final repo = PeriodRepository();
      final first = _period('2026-07-24', '2026-08-08');
      final second = _period('2026-08-09', '2026-08-23');
      final periods = [first, second];

      final viaFirst = repo.mileageCycleFor(first, periods);
      final viaSecond = repo.mileageCycleFor(second, periods);

      expect(viaFirst, isNotNull);
      expect(viaSecond, isNotNull);
      expect(viaFirst!.fileId, viaSecond!.fileId);
    });

    test('multiple cycles in a longer list are all found, sorted input not required', () {
      final repo = PeriodRepository();
      final aFirst = _period('2026-06-24', '2026-07-08');
      final aSecond = _period('2026-07-09', '2026-07-23');
      final bFirst = _period('2026-07-24', '2026-08-08');
      final bSecond = _period('2026-08-09', '2026-08-23');

      // Deliberately shuffled -- mileageCycles must sort internally.
      final cycles = repo.mileageCycles([bSecond, aFirst, bFirst, aSecond]);

      expect(cycles, hasLength(2));
      expect(cycles[0].fileId, '2026-06-24_2026-07-23');
      expect(cycles[1].fileId, '2026-07-24_2026-08-23');
    });
  });

  group('pastMileageCycles / pastOrphanedPeriods (Пакет 8a of the 4-week Mileage-cycle plan, '
      'whimsical-booping-salamander.md: the archive lists past cycles, plus any past period that '
      'never paired into one, so nothing silently vanishes -- section 5/14\'s standing principle)', () {
    test('pastMileageCycles keeps cycles that ended before the current cycle started, excludes the current one',
        () {
      final repo = PeriodRepository();
      final pastFirst = _period('2026-06-24', '2026-07-08');
      final pastSecond = _period('2026-07-09', '2026-07-23');
      final currentFirst = _period('2026-07-24', '2026-08-08');
      final currentSecond = _period('2026-08-09', '2026-08-23');
      final periods = [pastFirst, pastSecond, currentFirst, currentSecond];
      final currentCycle = repo.mileageCycleFor(currentSecond, periods)!;

      final result = repo.pastMileageCycles(periods, currentSecond, currentCycle);

      expect(result, hasLength(1));
      expect(result.single.fileId, '2026-06-24_2026-07-23');
    });

    test('pastMileageCycles sorts results descending by start (most recent first)', () {
      final repo = PeriodRepository();
      final oldestFirst = _period('2026-04-24', '2026-05-08');
      final oldestSecond = _period('2026-05-09', '2026-05-23');
      final middleFirst = _period('2026-05-24', '2026-06-08');
      final middleSecond = _period('2026-06-09', '2026-06-23');
      final newestFirst = _period('2026-06-24', '2026-07-08');
      final newestSecond = _period('2026-07-09', '2026-07-23');
      final currentFirst = _period('2026-07-24', '2026-08-08');
      final currentSecond = _period('2026-08-09', '2026-08-23');
      final periods = [
        oldestFirst,
        oldestSecond,
        middleFirst,
        middleSecond,
        newestFirst,
        newestSecond,
        currentFirst,
        currentSecond,
      ];
      final currentCycle = repo.mileageCycleFor(currentSecond, periods)!;

      final result = repo.pastMileageCycles(periods, currentSecond, currentCycle);

      expect(result.map((c) => c.fileId).toList(), [
        '2026-06-24_2026-07-23',
        '2026-05-24_2026-06-23',
        '2026-04-24_2026-05-23',
      ]);
    });

    test('pastMileageCycles falls back to currentPeriod.start when currentCycle is null '
        '(the current period is itself orphaned) -- archive still renders sensibly, not crash or empty', () {
      final repo = PeriodRepository();
      final pastFirst = _period('2026-06-24', '2026-07-08');
      final pastSecond = _period('2026-07-09', '2026-07-23');
      // A "9-23" period with no preceding "24-8" half -- orphaned, exactly
      // like the real seed data's very first period.
      final orphanedCurrent = _period('2026-08-09', '2026-08-23');
      final periods = [pastFirst, pastSecond, orphanedCurrent];

      expect(repo.mileageCycleFor(orphanedCurrent, periods), isNull, reason: 'sanity: it really is orphaned');

      final result = repo.pastMileageCycles(periods, orphanedCurrent, null);

      expect(result, hasLength(1));
      expect(result.single.fileId, '2026-06-24_2026-07-23');
    });

    test('pastMileageCycles is empty when there are no past cycles', () {
      final repo = PeriodRepository();
      final currentFirst = _period('2026-07-24', '2026-08-08');
      final currentSecond = _period('2026-08-09', '2026-08-23');
      final periods = [currentFirst, currentSecond];
      final currentCycle = repo.mileageCycleFor(currentSecond, periods)!;

      expect(repo.pastMileageCycles(periods, currentSecond, currentCycle), isEmpty);
    });

    test('pastOrphanedPeriods finds the real seed-data shape: a past period with no preceding "24-8" half',
        () {
      final repo = PeriodRepository();
      // The actual real-world case: the very first period ever recorded.
      final theOrphan = _period('2026-03-09', '2026-03-23');
      final pairedFirst = _period('2026-03-24', '2026-04-08');
      final pairedSecond = _period('2026-04-09', '2026-04-23');
      final current = _period('2026-08-09', '2026-08-23');
      final periods = [theOrphan, pairedFirst, pairedSecond, current];

      final result = repo.pastOrphanedPeriods(periods, current);

      expect(result, [theOrphan]);
    });

    test('pastOrphanedPeriods excludes periods that DO belong to a past cycle', () {
      final repo = PeriodRepository();
      final pairedFirst = _period('2026-06-24', '2026-07-08');
      final pairedSecond = _period('2026-07-09', '2026-07-23');
      final current = _period('2026-08-09', '2026-08-23');

      final result = repo.pastOrphanedPeriods([pairedFirst, pairedSecond, current], current);

      expect(result, isEmpty);
    });

    test('pastOrphanedPeriods excludes the current period even if it is itself orphaned', () {
      final repo = PeriodRepository();
      final orphanedCurrent = _period('2026-08-09', '2026-08-23');

      expect(repo.pastOrphanedPeriods([orphanedCurrent], orphanedCurrent), isEmpty);
    });

    test('pastOrphanedPeriods is empty when every past period pairs into a cycle', () {
      final repo = PeriodRepository();
      final pairedFirst = _period('2026-06-24', '2026-07-08');
      final pairedSecond = _period('2026-07-09', '2026-07-23');
      final currentFirst = _period('2026-07-24', '2026-08-08');
      final currentSecond = _period('2026-08-09', '2026-08-23');

      final result =
          repo.pastOrphanedPeriods([pairedFirst, pairedSecond, currentFirst, currentSecond], currentSecond);

      expect(result, isEmpty);
    });
  });

  group('findByFileId (Пакет 8: resolve a tapped reminder notification back to its period)', () {
    test('finds the period whose fileId matches', () {
      final repo = PeriodRepository();
      final target = _period('2026-08-09', '2026-08-23');
      final other = _period('2026-08-24', '2026-09-08');

      final found = repo.findByFileId([other, target], target.fileId);

      expect(found, target);
    });

    test('returns null when no period matches', () {
      final repo = PeriodRepository();
      final period = _period('2026-08-09', '2026-08-23');

      expect(repo.findByFileId([period], '2099-01-01_2099-01-15'), isNull);
    });
  });
}
