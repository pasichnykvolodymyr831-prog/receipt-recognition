import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/main.dart';

void main() {
  testWidgets('App boots and shows the ExpenseFlow app bar', (WidgetTester tester) async {
    await tester.pumpWidget(const ExpenseFlowApp());
    await tester.pump();

    expect(find.text('ExpenseFlow'), findsOneWidget);
  });
}
