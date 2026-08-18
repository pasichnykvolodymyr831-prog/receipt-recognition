import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/utils/number_input.dart';
import 'package:expenseflow/xlsx/formula_eval.dart';

void main() {
  group('evaluateFormula', () {
    test('addition chain resolves each cell via the resolver', () {
      final cells = {'H8': 1.0, 'G8': 2.0, 'F8': 3.0, 'E8': 4.0, 'D8': 5.0, 'C8': 6.0};
      final result = evaluateFormula('+H8+G8+F8+E8+D8+C8', (ref) => cells[ref]);
      expect(result, 21.0);
    });

    test('single-column SUM range', () {
      final cells = {'C8': 10.0, 'C9': 20.0, 'C10': 30.0};
      final result = evaluateFormula('SUM(C8:C10)', (ref) => cells[ref] ?? 0.0);
      expect(result, 60.0);
    });

    test('two-column SUM range (merge-spanning, e.g. I:J)', () {
      final cells = {'I8': 5.0, 'J8': 0.0, 'I9': 7.0, 'J9': 0.0};
      final result = evaluateFormula('SUM(I8:J9)', (ref) => cells[ref] ?? 0.0);
      expect(result, 12.0);
    });

    test('SUM wrapping a product with an absolute reference', () {
      // resolveCell always receives the normalized ref (\$ signs stripped),
      // matching how _recomputeFormulaValues keys its cell map.
      final cells = {'C2': 42.5, 'G1': 0.56};
      final result = evaluateFormula('SUM(C2*\$G\$1)', (ref) => cells[ref]);
      expect(result, closeTo(23.8, 1e-9));
    });

    test('blank/absent operand resolves as 0, not a failure', () {
      // Resolver mimics _recomputeFormulaValues: absent cell -> 0.0.
      final cells = {'C8': 10.0};
      final result = evaluateFormula('SUM(C8:C10)', (ref) => cells[ref] ?? 0.0);
      expect(result, 10.0);
    });

    test('a resolver returning null for one operand propagates to null for the whole formula', () {
      final result = evaluateFormula('+H8+G8', (ref) => ref == 'G8' ? null : 1.0);
      expect(result, isNull, reason: 'a text/unresolvable cell must not be silently treated as 0');
    });

    test('SUM over a range with one unresolvable cell also returns null', () {
      final result = evaluateFormula('SUM(C8:C9)', (ref) => ref == 'C9' ? null : 5.0);
      expect(result, isNull);
    });

    test('chained dependency: resolver itself recursively evaluates another formula', () {
      // Mimics _recomputeFormulaValues' memoized resolve() closure: L8 = +K8+I8,
      // where I8 is itself a formula the resolver evaluates on demand.
      double? resolve(String ref) {
        if (ref == 'I8') return evaluateFormula('+H8+G8', resolve);
        const values = {'K8': 100.0, 'H8': 3.0, 'G8': 4.0};
        return values[ref];
      }

      final result = evaluateFormula('+K8+I8', resolve);
      expect(result, 107.0);
    });

    test('a circular reference returns null instead of hanging', () {
      final visiting = <String>{};
      double? resolve(String ref) {
        if (visiting.contains(ref)) return null;
        visiting.add(ref);
        try {
          if (ref == 'A1') return evaluateFormula('+B1', resolve);
          if (ref == 'B1') return evaluateFormula('+A1', resolve);
          return null;
        } finally {
          visiting.remove(ref);
        }
      }

      expect(evaluateFormula('+A1', resolve), isNull);
    });

    test('malformed formula text returns null without throwing', () {
      expect(evaluateFormula('+H8+', (ref) => 1.0), isNull);
      expect(evaluateFormula('SUM(', (ref) => 1.0), isNull);
      expect(evaluateFormula(')(', (ref) => 1.0), isNull);
      expect(evaluateFormula('#REF!', (ref) => 1.0), isNull);
    });

    test('float-tail-prone case rounds cleanly once round2 is applied by the caller', () {
      final cells = {'A1': 0.1, 'A2': 0.2};
      final result = evaluateFormula('+A1+A2', (ref) => cells[ref]);
      expect(round2(result!), 0.3);
    });

    test('a single trailing cell reference (leading +) resolves directly', () {
      final result = evaluateFormula('+L28', (ref) => ref == 'L28' ? 250.0 : null);
      expect(result, 250.0);
    });

    test('plain numeric literal formula (no cell refs)', () {
      expect(evaluateFormula('1+1', (ref) => null), 2.0);
    });
  });
}
