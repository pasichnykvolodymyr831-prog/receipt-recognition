// Пакет 32 (audit 2026-08-18): formatDate is the newly-shared replacement
// for date formatting that used to be reimplemented independently in 6
// places across lib/screens.
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/utils/time_format.dart';

void main() {
  group('formatDate', () {
    test('pads single-digit month and day with a leading zero', () {
      expect(formatDate(DateTime(2026, 1, 5)), '2026-01-05');
    });

    test('leaves double-digit month and day unpadded', () {
      expect(formatDate(DateTime(2026, 12, 23)), '2026-12-23');
    });

    test('ignores any time-of-day component', () {
      expect(formatDate(DateTime(2026, 8, 9, 16, 30, 45)), '2026-08-09');
    });
  });
}
