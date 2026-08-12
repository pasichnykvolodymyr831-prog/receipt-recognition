import 'package:flutter/material.dart';

/// Holds the app's current UI language ('en' or 'ru') and notifies
/// listeners when it changes, so [AppLocale.of(context)] rebuilds any
/// dependent widget without a full app restart. Not tied to the device's
/// system locale -- this is purely the Settings screen's language toggle
/// (section 11).
class LocaleController extends ChangeNotifier {
  String _languageCode;

  LocaleController(String initialLanguageCode) : _languageCode = initialLanguageCode;

  String get languageCode => _languageCode;

  void setLanguage(String code) {
    if (_languageCode == code) return;
    _languageCode = code;
    notifyListeners();
  }
}

class AppLocale extends InheritedNotifier<LocaleController> {
  const AppLocale({super.key, required LocaleController controller, required super.child})
      : super(notifier: controller);

  static LocaleController of(BuildContext context) {
    final widget = context.dependOnInheritedWidgetOfExactType<AppLocale>();
    assert(widget != null, 'No AppLocale found in context');
    return widget!.notifier!;
  }
}
