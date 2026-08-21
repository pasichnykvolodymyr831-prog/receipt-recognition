import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/mileage_cycle.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';

/// One offerable file, resolved and gated independently of the others
/// (whimsical-booping-salamander.md, Пакет 4/8c). [_MileageEntry.cycle]
/// being `null` means the period isn't paired into a cycle yet at all --
/// distinct from a paired cycle whose file retention has since removed.
sealed class _FileEntry {
  Future<File?> resolve(PeriodFileManager fileManager);
}

class _MileageEntry extends _FileEntry {
  final MileageCycle? cycle;
  _MileageEntry(this.cycle);
  @override
  Future<File?> resolve(PeriodFileManager fileManager) async {
    final cycle = this.cycle;
    return cycle == null ? null : fileManager.mileageReportFile(cycle);
  }
}

class _TimesheetEntry extends _FileEntry {
  final PayrollPeriod period;
  _TimesheetEntry(this.period);
  @override
  Future<File?> resolve(PeriodFileManager fileManager) => fileManager.timesheetFile(period);
}

class _ResolvedEntry {
  final _FileEntry entry;
  final bool exists;
  const _ResolvedEntry(this.entry, this.exists);
}

/// Share / Save (section 12): send the period's or Mileage cycle's Excel
/// file(s) through the system share sheet, or save them to the device via
/// the native SAF save dialog. No photos are ever included -- only the
/// xlsx files.
///
/// Two entry points, since a 2-week [PayrollPeriod] (the current period,
/// via [ShareSaveScreen.forPeriod]) offers up to 2 files (its own Timesheet
/// + its Mileage cycle's Report), while a full [MileageCycle] (an archived
/// cycle, via [ShareSaveScreen.forCycle]) offers 3 (the shared Mileage
/// Report + BOTH constituent periods' own Timesheets -- Timesheet stays
/// 2-weekly, unchanged). Every file is checked and selectable independently
/// (Пакет 4): accounting only accepts Mileage Report every 4 weeks, so it's
/// an entirely normal, non-error state for some files to be ready while
/// others aren't.
class ShareSaveScreen extends StatefulWidget {
  final PayrollPeriod? period;
  final MileageCycle? cycle;

  const ShareSaveScreen.forPeriod({super.key, required this.period}) : cycle = null;
  const ShareSaveScreen.forCycle({super.key, required this.cycle}) : period = null;

  @override
  State<ShareSaveScreen> createState() => _ShareSaveScreenState();
}

class _ShareSaveScreenState extends State<ShareSaveScreen> {
  bool _busy = false;
  List<bool>? _checked;
  late Future<List<_ResolvedEntry>> _resolvedFuture;

  @override
  void initState() {
    super.initState();
    // Section 12/14: reached normally only through an enabled
    // PeriodActionTiles/MileageCycleDetailScreen tile -- this is the
    // defensive "refuse on entry with an explanation" backstop the plan
    // calls for, for any other path that might reach this screen (Пакет 10).
    _resolvedFuture = _resolve();
  }

  Future<List<_FileEntry>> _buildEntries() async {
    final cycle = widget.cycle;
    if (cycle != null) {
      return [_MileageEntry(cycle), _TimesheetEntry(cycle.firstHalf), _TimesheetEntry(cycle.secondHalf)];
    }
    final period = widget.period!;
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    return [_MileageEntry(periodRepo.mileageCycleFor(period, periods)), _TimesheetEntry(period)];
  }

  Future<List<_ResolvedEntry>> _resolve() async {
    final entries = await _buildEntries();
    final fileManager = PeriodFileManager();
    final exists = await Future.wait(entries.map((e) async {
      final file = await e.resolve(fileManager);
      return file != null && await file.exists();
    }));
    return [for (var i = 0; i < entries.length; i++) _ResolvedEntry(entries[i], exists[i])];
  }

  Future<List<File>> _selectedFiles() async {
    final resolved = await _resolvedFuture;
    final fileManager = PeriodFileManager();
    final files = <File>[];
    for (var i = 0; i < resolved.length; i++) {
      if (_checked![i]) {
        final file = await resolved[i].entry.resolve(fileManager);
        if (file != null) files.add(file);
      }
    }
    return files;
  }

  Future<void> _share() async {
    setState(() => _busy = true);
    try {
      final files = await _selectedFiles();
      await SharePlus.instance.share(
        ShareParams(files: files.map((f) => XFile(f.path)).toList()),
      );
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'shareSave.shareError', {'error': '$e'}))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _saveToDevice() async {
    setState(() => _busy = true);
    try {
      final files = await _selectedFiles();
      for (final file in files) {
        await FlutterFileDialog.saveFile(
          params: SaveFileDialogParams(sourceFilePath: file.path),
        );
      }
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t(context, 'shareSave.saved'))));
      }
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'shareSave.saveError', {'error': '$e'}))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _labelFor(BuildContext context, _FileEntry entry, {required bool multiTimesheet}) {
    return switch (entry) {
      _MileageEntry() => t(context, 'shareSave.mileageReport'),
      // "Timesheet: <label>" only when there are two of them to tell apart
      // (the cycle case) -- plain "Timesheet" for the single-period case,
      // matching the label this screen always used before Пакет 8c.
      _TimesheetEntry(:final period) =>
        multiTimesheet ? t(context, 'archive.timesheetFor', {'label': periodLabel(period)}) : t(context, 'shareSave.timesheet'),
    };
  }

  String? _captionFor(BuildContext context, _FileEntry entry, bool exists) {
    if (exists) return null;
    if (entry is _MileageEntry && entry.cycle == null) return t(context, 'mileageCycle.notReadyMessage');
    return t(context, 'periodActions.filesUnavailable');
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'shareSave.title'))),
      body: FutureBuilder<List<_ResolvedEntry>>(
        future: _resolvedFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          // See PeriodDetailScreen's identical guard in
          // period_archive_screen.dart for why a real error must not be
          // conflated with "files removed" (Пакет 10, code-review
          // 2026-08-19).
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          final resolved = snapshot.data!;
          if (resolved.every((r) => !r.exists)) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t(context, 'period.filesUnavailableMessage'), textAlign: TextAlign.center),
              ),
            );
          }
          return _buildContent(context, resolved);
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, List<_ResolvedEntry> resolved) {
    // Default: everything that's actually available is pre-checked (mirrors
    // this screen's old "Both" default when both files existed).
    _checked ??= resolved.map((r) => r.exists).toList();
    final multiTimesheet = resolved.where((r) => r.entry is _TimesheetEntry).length > 1;
    final anyChecked = _checked!.any((c) => c);

    return _busy
        ? const Center(child: CircularProgressIndicator())
        : ListView(
            padding: const EdgeInsets.all(16),
            children: [
              for (var i = 0; i < resolved.length; i++)
                CheckboxListTile(
                  title: Text(_labelFor(context, resolved[i].entry, multiTimesheet: multiTimesheet)),
                  subtitle: () {
                    final caption = _captionFor(context, resolved[i].entry, resolved[i].exists);
                    return caption == null ? null : Text(caption);
                  }(),
                  value: _checked![i],
                  onChanged: resolved[i].exists ? (v) => setState(() => _checked![i] = v ?? false) : null,
                ),
              const SizedBox(height: 24),
              FilledButton.icon(
                onPressed: anyChecked ? _share : null,
                icon: const Icon(Icons.ios_share),
                label: Text(t(context, 'shareSave.share')),
              ),
              const SizedBox(height: 12),
              OutlinedButton.icon(
                onPressed: anyChecked ? _saveToDevice : null,
                icon: const Icon(Icons.save_alt),
                label: Text(t(context, 'shareSave.saveToDevice')),
              ),
            ],
          );
  }
}
