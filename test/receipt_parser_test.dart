import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/services/receipt_parser.dart';

void main() {
  final today = DateTime(2026, 8, 11);

  group('date parsing', () {
    test('unambiguous DD/MM (month candidate would be in the future) resolves correctly', () {
      // 10/08/26: as DD/MM -> Aug 10 2026 (past); as MM/DD -> Oct 8 2026 (future, dropped).
      final result = parseReceiptText(['Home Depot', '10/08/26', 'SUBTOTAL 45.99'], today: today);
      expect(result.date, DateTime(2026, 8, 10));
    });

    test('ambiguous date resolved by the 35-day plausibility window', () {
      // 05/08/26: as DD/MM -> Aug 5 2026 (within 35-day window of Aug 11);
      // as MM/DD -> May 8 2026 (outside the window) -> unambiguous pick.
      final result = parseReceiptText(['05/08/26'], today: today);
      expect(result.date, DateTime(2026, 8, 5));
    });

    test('genuinely ambiguous date (both interpretations far in the past) is left blank', () {
      // 05/06/26: DD/MM -> Jun 5; MM/DD -> May 6. Both outside the 35-day window.
      final result = parseReceiptText(['05/06/26'], today: today);
      expect(result.date, isNull);
    });

    test('both interpretations plausible and in-window stays blank rather than guessing', () {
      final closeToday = DateTime(2026, 4, 8);
      // 03/04/26: DD/MM -> Apr 3; MM/DD -> Mar 4. Both within 35 days of Apr 8.
      final result = parseReceiptText(['03/04/26'], today: closeToday);
      expect(result.date, isNull);
    });

    test('missing date (RONA-style receipt) leaves the field blank without blocking other fields', () {
      final result = parseReceiptText(['RONA', 'SUBTOTAL 12.34', 'GST 0.62'], today: today);
      expect(result.date, isNull);
      expect(result.subtotal, 12.34);
      expect(result.gst, 0.62);
    });

    test('a future date is rejected even as the sole candidate', () {
      final result = parseReceiptText(['25/12/26'], today: today); // Dec 25 2026, month>12 rules out the other reading
      expect(result.date, isNull);
    });
  });

  group('amount parsing', () {
    test('Subtotal is matched case-insensitively', () {
      final result = parseReceiptText(['subtotal: \$45.99', 'GST 2.30'], today: today);
      expect(result.subtotal, 45.99);
      expect(result.gst, 2.30);
    });

    test('"Sales Tax" is recognized as the GST field (Plumbateria-style receipt)', () {
      final result = parseReceiptText(['SUBTOTAL 50.00', 'Sales Tax 2.50', 'TOTAL 52.50'], today: today);
      expect(result.gst, 2.50);
    });

    test('"GST/HST" is recognized as the GST field', () {
      final result = parseReceiptText(['Subtotal 100.00', 'GST/HST 5.00'], today: today);
      expect(result.gst, 5.00);
    });

    test('amounts with thousands separators parse correctly', () {
      final result = parseReceiptText(['Subtotal 1,234.56'], today: today);
      expect(result.subtotal, 1234.56);
    });

    test('missing labels leave fields blank instead of guessing', () {
      final result = parseReceiptText(['Random store receipt', 'Thank you'], today: today);
      expect(result.subtotal, isNull);
      expect(result.gst, isNull);
    });
  });
}
