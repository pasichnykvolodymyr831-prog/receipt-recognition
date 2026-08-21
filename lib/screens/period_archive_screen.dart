import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/mileage_cycle.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
import 'driving_detail_list_screen.dart';
import 'period_actions.dart';
import 'receipt_list_screen.dart';
import 'share_save_screen.dart';
import 'timesheet_screen.dart';

/// One row of the archive list -- either a paired 4-week Mileage cycle, or
/// a lone [PayrollPeriod] that never paired into one (whimsical-booping-
/// salamander.md, Пакет 8a: the real seed-data case is the very first
/// period ever recorded, which structurally can never have a preceding
/// "24-8" half). Both must render, sorted together by their own start date
/// -- neither is ever silently dropped just because the other shape is
/// more common (section 5/14's standing "не пропадать молча" principle).
sealed class _ArchiveEntry {
  DateTime get start;
}

class _CycleEntry extends _ArchiveEntry {
  final MileageCycle cycle;
  _CycleEntry(this.cycle);
  @override
  DateTime get start => cycle.start;
}

class _OrphanEntry extends _ArchiveEntry {
  final PayrollPeriod period;
  _OrphanEntry(this.period);
  @override
  DateTime get start => period.start;
}

/// Section 14: a simple list/switcher of past periods (within the retention
/// window) that can be opened and edited through the exact same screens as
/// the current period.
class PeriodArchiveScreen extends StatefulWidget {
  const PeriodArchiveScreen({super.key});

  @override
  State<PeriodArchiveScreen> createState() => _PeriodArchiveScreenState();
}

class _PeriodArchiveScreenState extends State<PeriodArchiveScreen> {
  late Future<List<_ArchiveEntry>> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// Section 5/14: every past Mileage cycle -- plus every past period that
  /// never paired into one -- is listed here, whether or not its files are
  /// still on disk (a period the retention window has since cleaned up
  /// must show up with an explanation, see [PeriodDetailScreen], not
  /// disappear silently; Пакет 10). The actual "which cycles/periods count
  /// as past" logic lives in [PeriodRepository.pastMileageCycles] /
  /// [PeriodRepository.pastOrphanedPeriods], not here, matching the
  /// project's convention of keeping period-list filters as named,
  /// independently-testable methods on the repository (whimsical-booping-
  /// salamander.md, Пакет 8a -- supersedes the old pastPeriods-only list).
  Future<List<_ArchiveEntry>> _load() async {
    final periodRepo = PeriodRepository();
    final allPeriods = await periodRepo.loadAll();
    final current = periodRepo.findCurrent(allPeriods, DateTime.now());
    if (current == null) return [];
    final currentCycle = periodRepo.mileageCycleFor(current, allPeriods);

    final entries = <_ArchiveEntry>[
      for (final cycle in periodRepo.pastMileageCycles(allPeriods, current, currentCycle)) _CycleEntry(cycle),
      for (final period in periodRepo.pastOrphanedPeriods(allPeriods, current)) _OrphanEntry(period),
    ];
    entries.sort((a, b) => b.start.compareTo(a.start));
    return entries;
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'archive.title'))),
      body: FutureBuilder<List<_ArchiveEntry>>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final entries = snapshot.data ?? [];
          if (entries.isEmpty) {
            return Center(child: Text(t(context, 'archive.empty')));
          }
          return ListView.builder(
            itemCount: entries.length,
            itemBuilder: (context, index) {
              final entry = entries[index];
              return switch (entry) {
                _CycleEntry(:final cycle) => ListTile(
                    title: Text(cycleLabel(cycle)),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context) => MileageCycleDetailScreen(cycle: cycle)),
                      );
                    },
                  ),
                _OrphanEntry(:final period) => ListTile(
                    title: Text(periodLabel(period)),
                    subtitle: Text(t(context, 'archive.orphanedPeriodCaption')),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () {
                      Navigator.of(context).push(
                        MaterialPageRoute(builder: (context) => PeriodDetailScreen(period: period)),
                      );
                    },
                  ),
              };
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
  // collapses "files exist" into one combined bool for all 6 tiles -- not
  // the real per-file-kind story once Mileage is cycle-keyed. As of Пакет
  // 8a this is OR (either kind present), not AND: an orphaned period (no
  // cycle at all -- Mileage structurally can't exist for it) or a period
  // whose cycle survived while its own Timesheet aged out (a real
  // possibility since Пакет 7) must still show its available tiles, not
  // report everything unavailable just because ONE kind is genuinely
  // missing. Safe to widen this way because every downstream screen
  // (Receipts/Trips list, Share/Save) already resolves its own cycle
  // independently and shows its own precise "not ready"/"unavailable"
  // state regardless of what this coarse gate said (Пакеты 3/4) -- this
  // bool only controls the top-level banner and whether tiles are tap-able
  // at all, not what each one actually shows once opened. Пакет 8b
  // replaces this whole screen with one that shows the 4 Mileage tiles + 2
  // Timesheet subtiles independently, per the plan.
  Future<bool> _checkFilesExist() async {
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    final cycle = periodRepo.mileageCycleFor(widget.period, periods);
    final fileManager = PeriodFileManager();
    final mileageExists = cycle != null && await (await fileManager.mileageReportFile(cycle)).exists();
    final timesheetExists = await (await fileManager.timesheetFile(widget.period)).exists();
    return mileageExists || timesheetExists;
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

/// A past Mileage cycle's own detail screen (section 14, whimsical-
/// booping-salamander.md Пакет 8b) -- deliberately NOT a generalization of
/// [PeriodActionTiles]: its fixed "6 uniform tiles for one entity" shape
/// doesn't fit "2 Mileage tiles for the whole cycle + 2 Timesheet subtiles
/// for its two distinct constituent periods", and forcing that
/// generalization would add more coupling than it removes (per the plan's
/// own assessment). Reuses the disabled+caption TILE PATTERN
/// [PeriodActionTiles] already established (Пакет 10) via [_DetailTile],
/// not the component itself.
///
/// Each of Receipts/Trips/Timesheet-first/Timesheet-second/Share-Save
/// checks its own file's existence independently, exactly like
/// [ShareSaveScreen] already does for Mileage vs Timesheet (Пакет 4) --
/// the whole point of a cycle now being able to survive while one half's
/// Timesheet doesn't, or vice versa (a real possibility since Пакет 7).
class MileageCycleDetailScreen extends StatefulWidget {
  final MileageCycle cycle;

  const MileageCycleDetailScreen({super.key, required this.cycle});

  @override
  State<MileageCycleDetailScreen> createState() => _MileageCycleDetailScreenState();
}

class _MileageCycleDetailScreenState extends State<MileageCycleDetailScreen> {
  late Future<bool> _mileageExistsFuture;
  late Future<bool> _firstHalfTimesheetExistsFuture;
  late Future<bool> _secondHalfTimesheetExistsFuture;

  @override
  void initState() {
    super.initState();
    final fileManager = PeriodFileManager();
    _mileageExistsFuture = fileManager.mileageReportFile(widget.cycle).then((f) => f.exists());
    _firstHalfTimesheetExistsFuture = fileManager.timesheetFile(widget.cycle.firstHalf).then((f) => f.exists());
    _secondHalfTimesheetExistsFuture = fileManager.timesheetFile(widget.cycle.secondHalf).then((f) => f.exists());
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(cycleLabel(widget.cycle))),
      body: FutureBuilder<List<bool>>(
        future: Future.wait(
            [_mileageExistsFuture, _firstHalfTimesheetExistsFuture, _secondHalfTimesheetExistsFuture]),
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          // Same reasoning as PeriodDetailScreen/ShareSaveScreen: a real
          // error (e.g. PeriodFileAmbiguousException) must surface
          // distinctly, never be silently read as "nothing available".
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          final mileageExists = snapshot.data![0];
          final firstTimesheetExists = snapshot.data![1];
          final secondTimesheetExists = snapshot.data![2];
          final nothingExists = !mileageExists && !firstTimesheetExists && !secondTimesheetExists;

          return ListView(
            padding: const EdgeInsets.all(16),
            children: [
              // Same top-level heads-up as PeriodDetailScreen -- shown only
              // when NOTHING at all survives, not per-tile (each tile
              // already explains itself individually below).
              if (nothingExists) ...[
                Text(t(context, 'period.filesUnavailableMessage'), style: const TextStyle(fontStyle: FontStyle.italic)),
                const SizedBox(height: 16),
              ],
              _DetailTile(
                icon: Icons.receipt,
                label: t(context, 'home.receiptList'),
                enabled: mileageExists,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => ReceiptListScreen(period: widget.cycle.secondHalf)),
                ),
              ),
              _DetailTile(
                icon: Icons.list_alt,
                label: t(context, 'home.tripList'),
                enabled: mileageExists,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => DrivingDetailListScreen(period: widget.cycle.secondHalf)),
                ),
              ),
              _DetailTile(
                icon: Icons.schedule,
                label: t(context, 'archive.timesheetFor', {'label': periodLabel(widget.cycle.firstHalf)}),
                enabled: firstTimesheetExists,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => TimesheetScreen(period: widget.cycle.firstHalf)),
                ),
              ),
              _DetailTile(
                icon: Icons.schedule,
                label: t(context, 'archive.timesheetFor', {'label': periodLabel(widget.cycle.secondHalf)}),
                enabled: secondTimesheetExists,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => TimesheetScreen(period: widget.cycle.secondHalf)),
                ),
              ),
              _DetailTile(
                icon: Icons.ios_share,
                label: t(context, 'home.shareSave'),
                enabled: mileageExists || firstTimesheetExists || secondTimesheetExists,
                onTap: () => Navigator.of(context).push(
                  MaterialPageRoute(builder: (context) => ShareSaveScreen.forCycle(cycle: widget.cycle)),
                ),
              ),
            ],
          );
        },
      ),
    );
  }
}

class _DetailTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final bool enabled;
  final VoidCallback onTap;

  const _DetailTile({required this.icon, required this.label, required this.enabled, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: enabled ? null : Text(t(context, 'periodActions.filesUnavailable')),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
