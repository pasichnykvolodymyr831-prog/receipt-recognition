// Section 12/14, Пакет 10: a period whose files aren't on disk (retention
// already cleaned them up) must show its action tiles disabled with an
// explanation, never hidden or silently inert.
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/l10n/locale_controller.dart';
import 'package:expenseflow/models/payroll_period.dart';
import 'package:expenseflow/screens/period_actions.dart';

Widget _wrap(Widget child) {
  return AppLocale(
    controller: LocaleController('en'),
    child: MaterialApp(home: Scaffold(body: SingleChildScrollView(child: child))),
  );
}

void main() {
  final period = PayrollPeriod(
    key: 'p',
    start: DateTime(2026, 8, 9),
    end: DateTime(2026, 8, 23),
    due: DateTime(2026, 8, 21),
  );

  testWidgets('filesExist=false disables every tile with an explanation, tap does nothing', (tester) async {
    await tester
        .pumpWidget(_wrap(PeriodActionTiles(period: period, filesExist: false, allowAdding: true)));

    expect(find.text('Files not available for this period'), findsNWidgets(6));

    await tester.tap(find.text('Add receipt'));
    await tester.pumpAndSettle();

    // Tapping a disabled tile must not navigate away -- the sibling tiles
    // (only rendered on this same tiles screen, never on any pushed
    // screen) are still there.
    expect(find.text('Driving Details'), findsOneWidget);
    expect(find.text('Share / Save'), findsOneWidget);
  });

  testWidgets('filesExist=true shows no explanation on any tile', (tester) async {
    await tester.pumpWidget(_wrap(PeriodActionTiles(period: period, filesExist: true, allowAdding: true)));

    expect(find.text('Files not available for this period'), findsNothing);
  });

  testWidgets('allowAdding=false hides Add receipt and Driving Details entirely (archive)', (tester) async {
    await tester.pumpWidget(_wrap(PeriodActionTiles(period: period, filesExist: true, allowAdding: false)));

    expect(find.text('Add receipt'), findsNothing);
    expect(find.text('Driving Details'), findsNothing);
    // Viewing/editing already-saved data must still be reachable.
    expect(find.text('Receipts'), findsOneWidget);
    expect(find.text('Trips'), findsOneWidget);
    expect(find.text('Timesheet'), findsOneWidget);
    expect(find.text('Share / Save'), findsOneWidget);
  });

  testWidgets('allowAdding=true shows all six tiles (current period)', (tester) async {
    await tester.pumpWidget(_wrap(PeriodActionTiles(period: period, filesExist: true, allowAdding: true)));

    expect(find.text('Add receipt'), findsOneWidget);
    expect(find.text('Driving Details'), findsOneWidget);
  });
}
