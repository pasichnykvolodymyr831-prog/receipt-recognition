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

  /// The $/km default rate (section 11) -- unlike a period's own [kmRate]
  /// (`PayrollPeriod.kmRate`, which may be null), this one is mandatory and
  /// must be > 0: it's the fallback every period without its own rate uses.
  final double kmRate;

  const AppSettings({
    required this.languageCode,
    required this.firstName,
    required this.lastName,
    required this.phone,
    required this.retention,
    required this.kmRate,
  });

  static const defaults = AppSettings(
    languageCode: 'en',
    firstName: 'Truman',
    lastName: 'Homes',
    phone: '',
    retention: RetentionPolicy.threeMonths,
    kmRate: 0.56,
  );

  String get fullName => '$firstName $lastName'.trim();

  AppSettings copyWith({
    String? languageCode,
    String? firstName,
    String? lastName,
    String? phone,
    RetentionPolicy? retention,
    double? kmRate,
  }) {
    return AppSettings(
      languageCode: languageCode ?? this.languageCode,
      firstName: firstName ?? this.firstName,
      lastName: lastName ?? this.lastName,
      phone: phone ?? this.phone,
      retention: retention ?? this.retention,
      kmRate: kmRate ?? this.kmRate,
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
  static const _keyKmRate = 'settings.kmRate';

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
      kmRate: prefs.getDouble(_keyKmRate) ?? AppSettings.defaults.kmRate,
    );
  }

  Future<void> save(AppSettings settings) async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_keyLanguage, settings.languageCode);
    await prefs.setString(_keyFirstName, settings.firstName);
    await prefs.setString(_keyLastName, settings.lastName);
    await prefs.setString(_keyPhone, settings.phone);
    await prefs.setString(_keyRetention, settings.retention.name);
    await prefs.setDouble(_keyKmRate, settings.kmRate);
  }
}
