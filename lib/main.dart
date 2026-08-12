import 'package:flutter/material.dart';

import 'l10n/locale_controller.dart';
import 'screens/home_screen.dart';
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

  @override
  void initState() {
    super.initState();
    SettingsRepository().load().then((settings) {
      _localeController.setLanguage(settings.languageCode);
    });
  }

  @override
  Widget build(BuildContext context) {
    return AppLocale(
      controller: _localeController,
      child: MaterialApp(
        title: 'ExpenseFlow',
        theme: ThemeData(colorScheme: ColorScheme.fromSeed(seedColor: Colors.indigo)),
        home: const HomeScreen(),
      ),
    );
  }
}
