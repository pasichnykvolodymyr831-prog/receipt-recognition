import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../l10n/locale_controller.dart';
import '../services/period_repository.dart';
import '../services/settings_repository.dart';
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
  RetentionPolicy _retention = AppSettings.defaults.retention;

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
    if (mounted) setState(() => _loading = false);
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    await _repo.save(AppSettings(
      languageCode: _languageCode,
      firstName: _firstNameController.text.trim(),
      lastName: _lastNameController.text.trim(),
      phone: _phoneController.text.trim(),
      retention: _retention,
    ));
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
        builder: (context) => AddPeriodScreen(suggestedRange: repo.suggestNextPeriodRange(periods)),
      ),
    );
  }

  @override
  void dispose() {
    _firstNameController.dispose();
    _lastNameController.dispose();
    _phoneController.dispose();
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
