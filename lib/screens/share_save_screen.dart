import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/mileage_cycle.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';

enum _FileChoice { mileage, timesheet, both }

/// Share / Save (section 12): send the period's Excel file(s) through the
/// system share sheet, or save them to the device via the native SAF save
/// dialog. No photos are ever included -- only the xlsx files.
///
/// Mileage and Timesheet are checked independently (whimsical-booping-
/// salamander.md, Пакет 4): accounting only accepts Mileage Report every 4
/// weeks, so it's an entirely normal, non-error state for Timesheet to be
/// ready while [widget.period]'s Mileage cycle either hasn't formed yet or
/// hasn't been created yet.
class ShareSaveScreen extends StatefulWidget {
  final PayrollPeriod period;

  const ShareSaveScreen({super.key, required this.period});

  @override
  State<ShareSaveScreen> createState() => _ShareSaveScreenState();
}

class _ShareSaveScreenState extends State<ShareSaveScreen> {
  _FileChoice? _choice;
  bool _busy = false;
  late Future<MileageCycle?> _cycleFuture;
  late Future<bool> _mileageExistsFuture;
  late Future<bool> _timesheetExistsFuture;

  @override
  void initState() {
    super.initState();
    // Section 12/14: reached normally only through an enabled
    // PeriodActionTiles tile -- this is the defensive "refuse on entry with
    // an explanation" backstop the plan calls for, for any other path that
    // might reach this screen (Пакет 10).
    _cycleFuture = _resolveCycle();
    _mileageExistsFuture = _cycleFuture.then((cycle) async {
      if (cycle == null) return false;
      return (await PeriodFileManager().mileageReportFile(cycle)).exists();
    });
    _timesheetExistsFuture = PeriodFileManager().timesheetFile(widget.period).then((f) => f.exists());
  }

  Future<MileageCycle?> _resolveCycle() async {
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    return periodRepo.mileageCycleFor(widget.period, periods);
  }

  Future<List<File>> _selectedFiles() async {
    final fileManager = PeriodFileManager();
    final cycle = await _cycleFuture;
    switch (_choice!) {
      case _FileChoice.mileage:
        return [await fileManager.mileageReportFile(cycle!)];
      case _FileChoice.timesheet:
        return [await fileManager.timesheetFile(widget.period)];
      case _FileChoice.both:
        return [
          await fileManager.mileageReportFile(cycle!),
          await fileManager.timesheetFile(widget.period),
        ];
    }
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

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'shareSave.title'))),
      body: FutureBuilder<List<bool>>(
        future: Future.wait([_mileageExistsFuture, _timesheetExistsFuture]),
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
          final mileageExists = snapshot.data![0];
          final timesheetExists = snapshot.data![1];
          if (!mileageExists && !timesheetExists) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t(context, 'period.filesUnavailableMessage'), textAlign: TextAlign.center),
              ),
            );
          }
          return _buildContent(context, mileageExists: mileageExists, timesheetExists: timesheetExists);
        },
      ),
    );
  }

  Widget _buildContent(BuildContext context, {required bool mileageExists, required bool timesheetExists}) {
    // Default to whichever single choice is actually available when only
    // one of the two exists -- "Both" would otherwise be pre-selected but
    // disabled, an unusable initial state.
    _choice ??= mileageExists && timesheetExists
        ? _FileChoice.both
        : (mileageExists ? _FileChoice.mileage : _FileChoice.timesheet);

    return _busy
        ? const Center(child: CircularProgressIndicator())
        : RadioGroup<_FileChoice>(
            groupValue: _choice,
            onChanged: (v) => setState(() => _choice = v),
            child: ListView(
              padding: const EdgeInsets.all(16),
              children: [
                RadioListTile<_FileChoice>(
                  title: Text(t(context, 'shareSave.mileageReport')),
                  subtitle: mileageExists ? null : Text(t(context, 'mileageCycle.notReadyMessage')),
                  value: _FileChoice.mileage,
                  enabled: mileageExists,
                ),
                RadioListTile<_FileChoice>(
                  title: Text(t(context, 'shareSave.timesheet')),
                  subtitle: timesheetExists ? null : Text(t(context, 'periodActions.filesUnavailable')),
                  value: _FileChoice.timesheet,
                  enabled: timesheetExists,
                ),
                RadioListTile<_FileChoice>(
                  title: Text(t(context, 'shareSave.bothFiles')),
                  value: _FileChoice.both,
                  enabled: mileageExists && timesheetExists,
                ),
                const SizedBox(height: 24),
                FilledButton.icon(
                  onPressed: _share,
                  icon: const Icon(Icons.ios_share),
                  label: Text(t(context, 'shareSave.share')),
                ),
                const SizedBox(height: 12),
                OutlinedButton.icon(
                  onPressed: _saveToDevice,
                  icon: const Icon(Icons.save_alt),
                  label: Text(t(context, 'shareSave.saveToDevice')),
                ),
              ],
            ),
          );
  }
}
