import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../l10n/locale_controller.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
import '../services/safe_xlsx_write.dart';
import '../services/settings_repository.dart';
import '../utils/number_input.dart';
import '../xlsx/mileage_report_engine.dart';
import 'add_period_screen.dart';

class SettingsScreen extends StatefulWidget {
  const SettingsScreen({super.key});

  @override
  State<SettingsScreen> createState() => _SettingsScreenState();
}

class _SettingsScreenState extends State<SettingsScreen> {
  final _repo = SettingsRepository();
  bool _loading = true;
  bool _saving = false;

  String _languageCode = AppSettings.defaults.languageCode;
  final _firstNameController = TextEditingController();
  final _lastNameController = TextEditingController();
  final _phoneController = TextEditingController();
  final _kmRateController = TextEditingController();
  RetentionPolicy _retention = AppSettings.defaults.retention;

  // The rate as it was on disk when this screen loaded -- needed to detect
  // whether it actually changed on save (section 6.2's first rate-change
  // path only fires on a real change, compared with tolerance, not `==`).
  double _originalKmRate = AppSettings.defaults.kmRate;
  String? _kmRateError;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final settings = await _repo.load();
    _languageCode = settings.languageCode;
    _firstNameController.text = settings.firstName;
    _lastNameController.text = settings.lastName;
    _phoneController.text = settings.phone;
    _retention = settings.retention;
    _kmRateController.text = settings.kmRate.toString();
    _originalKmRate = settings.kmRate;
    if (mounted) setState(() => _loading = false);
  }

  /// Section 11: the rate is mandatory and must be > 0 -- unlike the period
  /// form's own rate field, there's no "leave it blank" here.
  bool _validate() {
    final rate = parseDecimal(_kmRateController.text);
    final error = rate == null
        ? t(context, 'settings.kmRateRequired')
        : (rate <= 0 ? t(context, 'settings.kmRateMustBePositive') : null);
    setState(() => _kmRateError = error);
    return error == null;
  }

  Future<void> _save() async {
    if (!_validate()) return;
    setState(() => _saving = true);
    final newKmRate = parseDecimal(_kmRateController.text)!;
    final newSettings = AppSettings(
      languageCode: _languageCode,
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
      phone: _phoneController.text.trim(),
      retention: _retention,
      kmRate: newKmRate,
    );
    await _repo.save(newSettings);

    // Section 6.2, first rate-change path: a changed Settings default
    // updates the calendar-current period's own km_rate AND its file's G1
    // together -- future periods pick up the new default at creation time
    // on their own, so only the current one needs updating here.
    if (!MileageReportEngine.ratesEqual(_originalKmRate, newKmRate)) {
      final periodRepo = PeriodRepository();
      final periods = await periodRepo.loadAll();
      final current = periodRepo.findCurrent(periods, DateTime.now());
      if (current != null) {
        await periodRepo.updatePeriod(current.copyWith(kmRate: newKmRate));
        final file = await PeriodFileManager().mileageReportFile(current);
        if (await file.exists()) {
          await changeMileagePeriodRate(file, newRate: newKmRate);
        }
      }
      _originalKmRate = newKmRate;
    }

    if (mounted) {
      AppLocale.of(context).setLanguage(_languageCode);
      setState(() => _saving = false);
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(context, 'settings.saved'))));
    }
  }

  Future<void> _addPeriod() async {
    final repo = PeriodRepository();
    final periods = await repo.loadAll();
    if (!mounted) return;
    await Navigator.of(context).push(
      MaterialPageRoute(
        builder: (context) => AddPeriodScreen(
          suggestedRange: repo.suggestNextPeriodRange(periods),
          existingPeriods: periods,
        ),
      ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
    _kmRateController.dispose();
    super.dispose();
  }

  static const _retentionKeys = {
    RetentionPolicy.never: 'settings.retentionNever',
    RetentionPolicy.oneMonth: 'settings.retentionOneMonth',
    RetentionPolicy.threeMonths: 'settings.retentionThreeMonths',
    RetentionPolicy.sixMonths: 'settings.retentionSixMonths',
    RetentionPolicy.oneYear: 'settings.retentionOneYear',
  };

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'settings.title'))),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                Text(t(context, 'settings.language'), style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                SegmentedButton<String>(
                  segments: [
                    ButtonSegment(value: 'en', label: Text(t(context, 'settings.english'))),
                    ButtonSegment(value: 'ru', label: Text(t(context, 'settings.russian'))),
                  ],
                  selected: {_languageCode},
                  onSelectionChanged: (s) => setState(() => _languageCode = s.first),
                ),
                const SizedBox(height: 24),
                Text(t(context, 'settings.employeeName'), style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _firstNameController,
                  decoration: InputDecoration(labelText: t(context, 'settings.firstName')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _lastNameController,
                  decoration: InputDecoration(labelText: t(context, 'settings.lastName')),
                ),
                const SizedBox(height: 24),
                TextField(
                  controller: _phoneController,
                  decoration: InputDecoration(labelText: t(context, 'settings.phone')),
                  keyboardType: TextInputType.phone,
                ),
                const SizedBox(height: 24),
                Text(t(context, 'settings.kmRateTitle'), style: const TextStyle(fontWeight: FontWeight.bold)),
                const SizedBox(height: 8),
                TextField(
                  controller: _kmRateController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: t(context, 'settings.kmRateLabel'), errorText: _kmRateError),
                  onChanged: (_) => setState(() => _kmRateError = null),
                ),
                const SizedBox(height: 24),
                Text(t(context, 'settings.retentionTitle'), style: const TextStyle(fontWeight: FontWeight.bold)),
                DropdownButton<RetentionPolicy>(
                  isExpanded: true,
                  value: _retention,
                  items: RetentionPolicy.values
                      .map((r) => DropdownMenuItem(value: r, child: Text(t(context, _retentionKeys[r]!))))
                      .toList(),
                  onChanged: (v) => setState(() => _retention = v!),
                ),
                const SizedBox(height: 24),
                FilledButton(
                  onPressed: _saving ? null : _save,
                  child: _saving ? const CircularProgressIndicator() : Text(t(context, 'common.save')),
                ),
                const SizedBox(height: 32),
                const Divider(),
                ListTile(
                  leading: const Icon(Icons.event),
                  title: Text(t(context, 'settings.addNextPeriod')),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: _addPeriod,
                ),
              ],
            ),
    );
  }
}
