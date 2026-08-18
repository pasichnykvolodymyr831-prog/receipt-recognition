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
}
