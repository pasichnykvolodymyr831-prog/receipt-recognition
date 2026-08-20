import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/app_startup.dart';
import '../services/period_file_manager.dart' show periodLabel;
import '../utils/time_format.dart';
import 'add_period_screen.dart';
import 'period_actions.dart';
import 'period_archive_screen.dart';
import 'settings_screen.dart';

class HomeScreen extends StatefulWidget {
  /// Section 5: tapping a due-date reminder notification calls this with
  /// the tapped period's [PayrollPeriod.fileId] payload.
  final void Function(String? payload)? onNotificationTap;

  const HomeScreen({super.key, this.onNotificationTap});

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  final _startup = AppStartupService();
  late Future<BootstrapData> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<BootstrapData> _load() async {
    final data = await _startup.loadCurrentState();
    if (data.current != null) {
      await _startup.prepareCurrentPeriod(
        data.current!,
        data.currentCycle,
        data.settings,
        data.allPeriods,
        onNotificationTap: widget.onNotificationTap,
      );
      await _startup.rescheduleAllReminders(data.allPeriods, data.settings.languageCode);
      final showReminder = await _startup.shouldShowLowPeriodsReminder(data.allPeriods, data.current!);
      if (showReminder && mounted) {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (!mounted) return;
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(
              content: Text(t(context, 'home.lowPeriodsReminder')),
              duration: const Duration(seconds: 6),
            ),
          );
        });
      }
    }
    return data;
  }

  void _reload() {
    setState(() => _future = _load());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text('ExpenseFlow')),
      body: FutureBuilder<BootstrapData>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          final data = snapshot.data!;
          if (data.current == null) {
            return AddPeriodScreen(
              blocking: true,
              suggestedRange: _startup.suggestNextPeriodRange(data.allPeriods),
              existingPeriods: data.allPeriods,
              onSaved: (_) => _reload(),
            );
          }
          return _buildHome(data.current!, data);
        },
      ),
    );
  }

  Widget _buildHome(PayrollPeriod current, BootstrapData data) {
    return RefreshIndicator(
      onRefresh: () async => _reload(),
      child: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Card(
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(t(context, 'home.currentPeriod'), style: const TextStyle(fontWeight: FontWeight.bold)),
                  const SizedBox(height: 4),
                  Text(periodLabel(current), style: const TextStyle(fontSize: 18)),
                  const SizedBox(height: 8),
                  Text('${t(context, 'home.due')} ${_formatDateTime(current.due)}'),
                  if (current.weekendAltDue != null)
                    Text('${t(context, 'home.weekendDue')} ${_formatDateTime(current.weekendAltDue!)}'),
                ],
              ),
            ),
          ),
          const SizedBox(height: 16),
          // The current period's Timesheet file always exists by the time
          // this builds -- prepareCurrentPeriod's ensureTimesheetFileExists
          // already ran in _load() above -- so this is a known constant,
          // not a value worth an extra file-existence read to recompute
          // (Пакет 10). The Mileage side may still be "not ready" if
          // currentCycle is null (orphaned period, no partner half added
          // yet) -- that's handled inside the destination screens
          // themselves (Пакет 3 of whimsical-booping-salamander.md), not
          // here at the tile level, since PeriodActionTiles' fixed 6-tile
          // shape has no room for a per-tile distinction.
          PeriodActionTiles(period: current, onChanged: _reload, filesExist: true, allowAdding: true),
          Card(
            child: ListTile(
              leading: const Icon(Icons.history),
              title: Text(t(context, 'home.pastPeriods')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () {
                Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const PeriodArchiveScreen()),
                );
              },
            ),
          ),
          Card(
            child: ListTile(
              leading: const Icon(Icons.settings),
              title: Text(t(context, 'home.settings')),
              trailing: const Icon(Icons.chevron_right),
              onTap: () async {
                await Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => const SettingsScreen()),
                );
                _reload();
              },
            ),
          ),
        ],
      ),
    );
  }
}

// Deliberately its own hour12:minute AM/PM formatting rather than reusing
// [formatClockTime] (Пакет 32, audit 2026-08-18): that helper's compact
// "430pm" shape matches the Timesheet's Excel-cell text convention, not a
// human-readable screen label -- forcing this label into that shape would
// be a real readability regression, not a meaningful deduplication. Only
// the date portion (genuinely identical everywhere) is shared.
String _formatDateTime(DateTime d) {
  final hour12 = d.hour % 12 == 0 ? 12 : d.hour % 12;
  final period = d.hour < 12 ? 'AM' : 'PM';
  final minute = d.minute.toString().padLeft(2, '0');
  return '${formatDate(d)} $hour12:$minute $period';
}
