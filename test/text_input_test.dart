// Section 8/9: Description/Trip free text must be trimmed, have embedded
// line breaks collapsed to a single space, and stay within a sane length as
// a save-time backstop (the primary limit lives on the input field itself).
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/utils/text_input.dart';

void main() {
  group('sanitizeFreeText', () {
    test('trims leading and trailing whitespace', () {
      expect(sanitizeFreeText('  Home Depot - filters  '), 'Home Depot - filters');
    });

    test('collapses a single embedded newline to a space', () {
      expect(sanitizeFreeText('Home Depot\nfilters, bulbs'), 'Home Depot filters, bulbs');
    });

    test('collapses multiple consecutive line breaks (incl. CRLF) to one space', () {
      expect(sanitizeFreeText('line one\r\n\r\nline two'), 'line one line two');
    });

    test('leaves short text under the length cap untouched', () {
      final text = 'Home Depot - toilet fill valve, garbage bags';
      expect(sanitizeFreeText(text), text);
    });

    test('truncates text longer than the cap', () {
      final text = 'x' * 400;
      final result = sanitizeFreeText(text, maxLength: 300);
      expect(result.length, 300);
    });

    test('empty input stays empty', () {
      expect(sanitizeFreeText(''), '');
      expect(sanitizeFreeText('   '), '');
    });

    test('does not alter a leading formula-like character -- sanitization is not escaping', () {
      // Section 8: values starting with =, +, -, @ must be preserved as
      // typed; making sure they're written as TEXT (not a formula) is the
      // cell-value layer's job (see mileage_report_engine writes via
      // TextCellValue), not this function's.
      expect(sanitizeFreeText('=SUM(A1:A2)'), '=SUM(A1:A2)');
    });
  });
}
