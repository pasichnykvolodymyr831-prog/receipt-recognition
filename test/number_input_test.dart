// Section 2 (comma/dot decimal separator) and sections 8/9/13.7 (rounding
// user-entered amounts to 2 decimals before they reach the xlsx file).
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/utils/number_input.dart';

void main() {
  group('parseDecimal', () {
    test('accepts a dot decimal separator', () {
      expect(parseDecimal('5.29'), 5.29);
    });

    test('accepts a comma decimal separator', () {
      expect(parseDecimal('5,29'), 5.29);
    });

    test('trims surrounding whitespace', () {
      expect(parseDecimal('  12.50  '), 12.50);
    });

    test('empty input parses to null', () {
      expect(parseDecimal(''), isNull);
      expect(parseDecimal('   '), isNull);
    });

    test('non-numeric input parses to null', () {
      expect(parseDecimal('abc'), isNull);
    });

    test('a bare negative sign parses to null, not a crash', () {
      expect(parseDecimal('-'), isNull);
    });

    test('negative numbers (return receipts) parse correctly with either separator', () {
      expect(parseDecimal('-12.34'), -12.34);
      expect(parseDecimal('-12,34'), -12.34);
    });
  });

  group('round2', () {
    test('rounds a long decimal tail to 2 places', () {
      expect(round2(12.3456), 12.35);
    });

    test('the classic 0.1 + 0.2 float-tail case rounds cleanly', () {
      expect(round2(0.1 + 0.2), 0.3);
    });

    test('already-2-decimal values are unchanged', () {
      expect(round2(45.99), 45.99);
    });

    test('rounds negative values (return receipts) correctly', () {
      expect(round2(-12.346), -12.35);
    });

    test('whole numbers stay whole', () {
      expect(round2(10.0), 10.0);
    });
  });
}
