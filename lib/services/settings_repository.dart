import 'package:shared_preferences/shared_preferences.dart';

enum RetentionPolicy { never, oneMonth, threeMonths, sixMonths, oneYear }

extension RetentionPolicyWindow on RetentionPolicy {
  /// Null means "keep nothing from the previous period" (delete immediately
  /// on new-period creation). Non-null is the retention window in days.
  int? get windowDays {
    switch (this) {
      case RetentionPolicy.never:
        return null;
      case RetentionPolicy.oneMonth:
        return 30;
      case RetentionPolicy.threeMonths:
        return 90;
      case RetentionPolicy.sixMonths:
        return 180;
      case RetentionPolicy.oneYear:
        return 365;
    }
  }
}

class AppSettings {
  final String languageCode; // 'en' or 'ru'
  final String firstName;
  final String lastName;
  final String phone;
  final RetentionPolicy retention;

  const AppSettings({
    required this.languageCode,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.retention,
  });

  static const defaults = AppSettings(
    languageCode: 'en',
    firstName: 'Truman',
    lastName: 'Homes',
    phone: '',
    retention: RetentionPolicy.threeMonths,
  );

  String get fullName => '$firstName $lastName'.trim();

  AppSettings copyWith({
    String? languageCode,
    String? firstName,
    String? lastName,
    String? phone,
    RetentionPolicy? retention,
  }) {
    return AppSettings(
      languageCode: languageCode ?? this.languageCode,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      phone: phone ?? this.phone,
      retention: retention ?? this.retention,
    );
  }
}

/// Thin persistence layer over shared_preferences (section 11).
class SettingsRepository {
  static const _keyLanguage = 'settings.language';
  static const _keyFirstName = 'settings.firstName';
  static const _keyLastName = 'settings.lastName';
  static const _keyPhone = 'settings.phone';
  static const _keyRetention = 'settings.retention';

  Future<AppSettings> load() async {
    final prefs = await SharedPreferences.getInstance();
    final retentionName = prefs.getString(_keyRetention);
    return AppSettings(
      languageCode: prefs.getString(_keyLanguage) ?? AppSettings.defaults.languageCode,
      firstName: prefs.getString(_keyFirstName) ?? AppSettings.defaults.firstName,
      lastName: prefs.getString(_keyLastName) ?? AppSettings.defaults.lastName,
      phone: prefs.getString(_keyPhone) ?? AppSettings.defaults.phone,
      retention: RetentionPolicy.values.firstWhere(
        (e) => e.name == retentionName,
        orElse: () => AppSettings.defaults.retention,
      ),
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLanguage, settings.languageCode);
    await prefs.setString(_keyFirstName, settings.firstName);
    await prefs.setString(_keyLastName, settings.lastName);
    await prefs.setString(_keyPhone, settings.phone);
    await prefs.setString(_keyRetention, settings.retention.name);
  }
}
