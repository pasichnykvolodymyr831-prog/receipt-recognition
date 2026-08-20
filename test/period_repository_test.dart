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
