import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
import 'period_actions.dart';

/// Section 14: a simple list/switcher of past periods (within the retention
/// window) that can be opened and edited through the exact same screens as
/// the current period.
class PeriodArchiveScreen extends StatefulWidget {
  const PeriodArchiveScreen({super.key});

  @override
  State<PeriodArchiveScreen> createState() => _PeriodArchiveScreenState();
}

class _PeriodArchiveScreenState extends State<PeriodArchiveScreen> {
  late Future<List<PayrollPeriod>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<List<PayrollPeriod>> _load() async {
    final periodRepo = PeriodRepository();
    final fileManager = PeriodFileManager();
    final allPeriods = await periodRepo.loadAll();
    final current = periodRepo.findCurrent(allPeriods, DateTime.now());
    final withFiles = await fileManager.listPeriodsWithFiles(allPeriods);
    return withFiles.where((p) => p.key != current?.key).toList();
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'archive.title'))),
      body: FutureBuilder<List<PayrollPeriod>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final periods = snapshot.data ?? [];
          if (periods.isEmpty) {
            return Center(child: Text(t(context, 'archive.empty')));
          }
          return ListView.builder(
            itemCount: periods.length,
            itemBuilder: (context, index) {
              final period = periods[index];
              return ListTile(
                title: Text(periodLabel(period)),
                trailing: const Icon(Icons.chevron_right),
                onTap: () {
                  Navigator.of(context).push(
                    MaterialPageRoute(builder: (context) => PeriodDetailScreen(period: period)),
                  );
                },
              );
            },
          );
        },
      ),
    );
  }
}

class PeriodDetailScreen extends StatelessWidget {
  final PayrollPeriod period;

  const PeriodDetailScreen({super.key, required this.period});

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(periodLabel(period))),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          PeriodActionTiles(period: period),
        ],
      ),
    );
  }
}
