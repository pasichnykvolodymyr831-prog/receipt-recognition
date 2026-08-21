// Section 12а, Пакет 11 of hazy-noodling-sprout.md: the one shared write
// progress/error overlay for all three Excel-write paths. Tests the
// controller/widget in isolation (not through any of the 3 screens) since
// its timing/back-block/error semantics are independent of what's being
// saved.
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/l10n/locale_controller.dart';
import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/widgets/save_progress_overlay.dart';

Widget _wrap(SaveProgressController controller, {VoidCallback? onRun}) {
  return AppLocale(
    controller: LocaleController('en'),
    child: MaterialApp(
      home: Scaffold(
        body: SaveProgressOverlay(
          controller: controller,
          child: Column(
            children: [
              const Text('content'),
              ElevatedButton(onPressed: onRun, child: const Text('trigger')),
            ],
          ),
        ),
      ),
    ),
  );
}

void main() {
  testWidgets('a fast action (under 400ms) never shows the overlay', (tester) async {
    final controller = SaveProgressController();
    await tester.pumpWidget(_wrap(controller));

    final future = controller.run(
      tester.element(find.byType(SaveProgressOverlay)),
      (onPhase) async {}, // completes instantly
      messageFor: (e) => (title: null, message: 'error'),
      successMessage: 'saved',
    );
    await tester.pump(); // let the immediate microtasks/action run
    await future;
    await tester.pump();

    expect(find.byType(CircularProgressIndicator), findsNothing);

    // Prove the 400ms delay timer was actually cancelled, not just "hasn't
    // fired yet" -- advance well past it and confirm it still never shows.
    await tester.pump(const Duration(milliseconds: 500));
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('an action still running after 400ms shows progress with the phase label', (tester) async {
    final controller = SaveProgressController();
    await tester.pumpWidget(_wrap(controller));
    final phaseCompleter = Completer<void>();

    final future = controller.run(
      tester.element(find.byType(SaveProgressOverlay)),
      (onPhase) async {
        onPhase(SaveXlsxPhase.writing);
        await phaseCompleter.future;
      },
      messageFor: (e) => (title: null, message: 'error'),
      successMessage: 'saved',
    );
    await tester.pump(const Duration(milliseconds: 400));

    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.text('Writing…'), findsOneWidget);

    phaseCompleter.complete();
    await future;
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });

  testWidgets('back navigation is blocked while busy, allowed once idle', (tester) async {
    final controller = SaveProgressController();
    await tester.pumpWidget(_wrap(controller));

    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, true);

    final gate = Completer<void>();
    final future = controller.run(
      tester.element(find.byType(SaveProgressOverlay)),
      (onPhase) async => gate.future,
      messageFor: (e) => (title: null, message: 'error'),
      successMessage: 'saved',
    );
    await tester.pump();

    final absorbPointer = find.descendant(of: find.byType(PopScope), matching: find.byType(AbsorbPointer)).first;
    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, false);
    expect(tester.widget<AbsorbPointer>(absorbPointer).absorbing, true);

    gate.complete();
    await future;
    await tester.pump();

    expect(tester.widget<PopScope>(find.byType(PopScope)).canPop, true);
  });

  testWidgets('a failed action shows a non-dismissing error immediately (no 400ms wait), OK dismisses it',
      (tester) async {
    final controller = SaveProgressController();
    await tester.pumpWidget(_wrap(controller));

    bool? result;
    unawaited(controller
        .run(
          tester.element(find.byType(SaveProgressOverlay)),
          (onPhase) async => throw Exception('boom'),
          messageFor: (e) => (title: 'Oops', message: 'Something went wrong'),
          successMessage: 'saved',
        )
        .then((r) => result = r));
    await tester.pump(); // error must appear well before the 400ms progress-delay would

    expect(find.text('Oops'), findsOneWidget);
    expect(find.text('Something went wrong'), findsOneWidget);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(result, isNull); // run() hasn't returned yet -- still waiting on the OK tap

    await tester.tap(find.text('OK'));
    await tester.pump();

    expect(find.text('Oops'), findsNothing);
    expect(result, false);
  });

  testWidgets('a successful action shows the success SnackBar', (tester) async {
    final controller = SaveProgressController();
    await tester.pumpWidget(_wrap(controller));

    await controller.run(
      tester.element(find.byType(SaveProgressOverlay)),
      (onPhase) async {},
      messageFor: (e) => (title: null, message: 'error'),
      successMessage: 'Saved!',
    );
    await tester.pump();

    expect(find.text('Saved!'), findsOneWidget);
  });
}
