import 'package:flutter/material.dart';

import 'l10n/locale_controller.dart';
import 'screens/home_screen.dart';
import 'screens/share_save_screen.dart';
import 'services/period_repository.dart';
import 'services/settings_repository.dart';

void main() {
  runApp(const ExpenseFlowApp());
}

class ExpenseFlowApp extends StatefulWidget {
  const ExpenseFlowApp({super.key});

  @override
  State<ExpenseFlowApp> createState() => _ExpenseFlowAppState();
}

class _ExpenseFlowAppState extends State<ExpenseFlowApp> {
  final _localeController = LocaleController(AppSettings.defaults.languageCode);
  // A GlobalKey is the standard way to navigate from a callback that fires
  // outside the widget tree (the notification plugin's platform channel),
  // where no BuildContext is available.
  final _navigatorKey = GlobalKey<NavigatorState>();

  @override
  void initState() {
    super.initState();
    SettingsRepository().load().then((settings) {
      _localeController.setLanguage(settings.languageCode);
    });
  }

  /// Section 5: tapping a due-date reminder opens that period's Share/Save
  /// screen directly. The payload is the tapped period's
  /// [PayrollPeriod.fileId] (see [NotificationService.scheduleDueReminder]).
  Future<void> _onNotificationTap(String? payload) async {
    if (payload == null) return;
    final repo = PeriodRepository();
    final periods = await repo.loadAll();
    final period = repo.findByFileId(periods, payload);
    if (period != null) {
      _navigatorKey.currentState?.push(
        MaterialPageRoute(builder: (context) => ShareSaveScreen.forPeriod(period: period)),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return AppLocale(
      controller: _localeController,
      child: MaterialApp(
        navigatorKey: _navigatorKey,
        title: 'ExpenseFlow',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
        home: HomeScreen(onNotificationTap: _onNotificationTap),
      ),
    );
  }
}
