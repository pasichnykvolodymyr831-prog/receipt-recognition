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

  /// Section 5/14: every past period is listed here, whether or not its
  /// files are still on disk -- a period the retention window has since
  /// cleaned up must show up with an explanation (see [PeriodDetailScreen]),
  /// not disappear silently (Пакет 10; previously filtered to only periods
  /// with files on disk, which hid exactly that case). The actual "which
  /// periods count as past" logic lives in [PeriodRepository.pastPeriods],
  /// not here, matching the project's convention of keeping period-list
  /// filters as named, independently-testable methods on the repository
  /// (see [PeriodRepository.periodsAfter]/[PeriodRepository.periodsWithFutureDue]).
  Future<List<PayrollPeriod>> _load() async {
    final periodRepo = PeriodRepository();
    final allPeriods = await periodRepo.loadAll();
    final current = periodRepo.findCurrent(allPeriods, DateTime.now());
    if (current == null) return [];
    return periodRepo.pastPeriods(allPeriods, current);
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

/// Section 14: a past period's action tiles, gated on whether its files are
/// actually still on disk -- an archived period the retention window has
/// cleaned up shows a top-level explanation plus the same
/// [PeriodActionTiles], disabled with their own per-tile explanation
/// (Пакет 10). Needs a file check, so this is a [StatefulWidget] rather
/// than the plain [StatelessWidget] it used to be.
class PeriodDetailScreen extends StatefulWidget {
  final PayrollPeriod period;

  const PeriodDetailScreen({super.key, required this.period});

  @override
  State<PeriodDetailScreen> createState() => _PeriodDetailScreenState();
}

class _PeriodDetailScreenState extends State<PeriodDetailScreen> {
  late Future<bool> _filesExistFuture;

  @override
  void initState() {
    super.initState();
    _filesExistFuture = _checkFilesExist();
  }

  // TODO(whimsical-booping-salamander.md, Пакет 8b): this screen still
  // treats "files exist" as one combined AND of Mileage+Timesheet, exactly
  // mirroring the pre-cycle behavior -- correct as a stopgap (Пакет 2), but
  // not the real per-file-kind story once Mileage is cycle-keyed (a past
  // period's Timesheet can be gone while its Mileage cycle is still live
  // for the other half, or vice versa). Пакет 8b replaces this whole
  // screen with one that shows the 4 Mileage tiles + 2 Timesheet subtiles
  // independently, per the plan.
  Future<bool> _checkFilesExist() async {
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    final cycle = periodRepo.mileageCycleFor(widget.period, periods);
    final fileManager = PeriodFileManager();
    final mileageExists = cycle != null && await (await fileManager.mileageReportFile(cycle)).exists();
    final timesheetExists = await (await fileManager.timesheetFile(widget.period)).exists();
    return mileageExists && timesheetExists;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(periodLabel(widget.period))),
      body: FutureBuilder<bool>(
        future: _filesExistFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          // A real error (e.g. PeriodFileAmbiguousException, when two+
          // candidate files exist for this period -- section 5's "не
          // выбирать наугад") must never be silently rendered as "files
          // removed"; that would hide the actual problem instead of the
          // one this screen is meant to surface (Пакет 10, code-review
          // 2026-08-19). Same pattern as receipt_list_screen.dart/
          // driving_detail_list_screen.dart.
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          final filesExist = snapshot.data ?? false;
          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              if (!filesExist) ...[
                Text(t(context, 'period.filesUnavailableMessage'), style: const TextStyle(fontStyle: FontStyle.italic)),
                const SizedBox(height: 16),
              ],
              PeriodActionTiles(period: widget.period, filesExist: filesExist, allowAdding: false),
            ],
          );
        },
      ),
    );
  }
}
