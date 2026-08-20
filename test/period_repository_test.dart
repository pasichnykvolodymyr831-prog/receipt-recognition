import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/services/period_repository.dart';

PayrollPeriod _period(String start, String end) => PayrollPeriod(
      key: '$start-$end',
      start: DateTime.parse(start),
      end: DateTime.parse(end),
      due: DateTime.parse(end),
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
