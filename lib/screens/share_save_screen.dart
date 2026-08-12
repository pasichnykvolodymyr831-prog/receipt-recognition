import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_file_dialog/flutter_file_dialog.dart';
import 'package:share_plus/share_plus.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';

enum _FileChoice { mileage, timesheet, both }

/// Share / Save (section 12): send the period's Excel file(s) through the
/// system share sheet, or save them to the device via the native SAF save
/// dialog. No photos are ever included -- only the xlsx files.
class ShareSaveScreen extends StatefulWidget {
  final PayrollPeriod period;

  const ShareSaveScreen({super.key, required this.period});

  @override
  State<ShareSaveScreen> createState() => _ShareSaveScreenState();
}

class _ShareSaveScreenState extends State<ShareSaveScreen> {
  _FileChoice _choice = _FileChoice.both;
  bool _busy = false;

  Future<List<File>> _selectedFiles() async {
    final fileManager = PeriodFileManager();
    switch (_choice) {
      case _FileChoice.mileage:
        return [await fileManager.mileageReportFile(widget.period)];
      case _FileChoice.timesheet:
        return [await fileManager.timesheetFile(widget.period)];
      case _FileChoice.both:
        return [
          await fileManager.mileageReportFile(widget.period),
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
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : RadioGroup<_FileChoice>(
              groupValue: _choice,
              onChanged: (v) => setState(() => _choice = v!),
              child: ListView(
                padding: const EdgeInsets.all(16),
                children: [
                  RadioListTile<_FileChoice>(
                    title: Text(t(context, 'shareSave.mileageReport')),
                    value: _FileChoice.mileage,
                  ),
                  RadioListTile<_FileChoice>(
                    title: Text(t(context, 'shareSave.timesheet')),
                    value: _FileChoice.timesheet,
                  ),
                  RadioListTile<_FileChoice>(
                    title: Text(t(context, 'shareSave.bothFiles')),
                    value: _FileChoice.both,
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
            ),
    );
  }
}
