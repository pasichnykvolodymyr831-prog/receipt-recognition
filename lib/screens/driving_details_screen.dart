import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/safe_xlsx_write.dart';
import '../services/settings_repository.dart';
import '../utils/number_input.dart';
import '../utils/text_input.dart';
import '../utils/time_format.dart';
import '../xlsx/mileage_report_engine.dart';

/// Manual Driving Details entry (section 9): Date, Trip, KM. Writes to the
/// first free row (2-18) and triggers the Kilometers row recalculation.
class DrivingDetailsScreen extends StatefulWidget {
  final PayrollPeriod period;

  /// When set, this screen edits an already-saved trip in place (section
  /// 14) instead of adding a new one -- fields prefilled, no free-row
  /// search on save.
  final DrivingDetailRecord? existing;

  const DrivingDetailsScreen({super.key, required this.period, this.existing});

  @override
  State<DrivingDetailsScreen> createState() => _DrivingDetailsScreenState();
}

class _DrivingDetailsScreenState extends State<DrivingDetailsScreen> {
  DateTime _date = DateTime.now();
  final _tripController = TextEditingController();
  final _kmController = TextEditingController();
  bool _busy = false;
  SaveXlsxPhase? _savePhase;

  // Section 9: Trip is required, KM must be strictly > 0.
  String? _tripError;
  String? _kmError;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      if (existing.date != null) _date = existing.date!;
      _tripController.text = existing.trip;
      _kmController.text = existing.km?.toStringAsFixed(2) ?? '';
    }
  }

  @override
  void dispose() {
    _tripController.dispose();
    _kmController.dispose();
    super.dispose();
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: widget.period.start,
      lastDate: widget.period.end,
    );
    if (!mounted) return;
    if (picked != null) setState(() => _date = picked);
  }

  /// Section 9: Trip is required (free text, no autocomplete); KM must be
  /// strictly greater than zero (a zero/negative trip is almost certainly a
  /// typo, and there's no meaningful upper bound to enforce).
  bool _validate() {
    final trip = sanitizeFreeText(_tripController.text);
    final km = parseDecimal(_kmController.text);

    final tripError = trip.isEmpty ? t(context, 'drivingDetails.tripRequired') : null;
    final kmError = km == null
        ? t(context, 'drivingDetails.invalidKm')
        : (km <= 0 ? t(context, 'drivingDetails.kmMustBePositive') : null);

    setState(() {
      _tripError = tripError;
      _kmError = kmError;
    });
    return tripError == null && kmError == null;
  }

  Future<void> _save() async {
    if (_busy) return; // guards against a second tap starting a concurrent write
    if (!_validate()) return;
    // Section 9: round to 2 decimals here -- a typed "42.567" must never
    // reach the file as anything longer than 42.57.
    final km = round2(parseDecimal(_kmController.text)!);
    final trip = sanitizeFreeText(_tripController.text);

    setState(() {
      _busy = true;
      _savePhase = SaveXlsxPhase.reading;
    });
    try {
      final fileManager = PeriodFileManager();
      final file = await fileManager.mileageReportFile(widget.period);
      final settings = await SettingsRepository().load();
      void onPhase(SaveXlsxPhase phase) {
        if (mounted) setState(() => _savePhase = phase);
      }

      final existing = widget.existing;
      if (existing != null) {
        // Section 14: editing writes back to the same row -- no free-row
        // search, unlike saveMileageDrivingDetail.
        await updateMileageDrivingDetail(
          file,
          row: existing.row,
          date: _date,
          trip: trip,
          km: km,
          periodKmRate: widget.period.kmRate,
          settingsDefaultRate: settings.kmRate,
          onPhase: onPhase,
        );
      } else {
        await saveMileageDrivingDetail(
          file,
          date: _date,
          trip: trip,
          km: km,
          periodKmRate: widget.period.kmRate,
          settingsDefaultRate: settings.kmRate,
          onPhase: onPhase,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } on MileageReportRowsExhaustedException {
      if (mounted) {
        setState(() => _busy = false);
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t(context, 'mileageReport.noRoomTitle')),
            content: Text(t(context, 'drivingDetails.noRoomContent')),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t(context, 'common.ok'))),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'drivingDetails.saveError', {'error': '$e'}))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = formatDate(_date);

    return Scaffold(
      appBar: AppBar(
        title: Text(t(context, widget.existing != null ? 'drivingDetails.editTitle' : 'drivingDetails.title')),
      ),
      body: _busy
          ? _buildSaveProgress(context)
          : ListView(
              padding: const EdgeInsets.all(16),
              children: [
                ListTile(
                  title: Text(t(context, 'addReceipt.date')),
                  subtitle: Text(dateFmt),
                  trailing: const Icon(Icons.calendar_today),
                  onTap: _pickDate,
                ),
                const Divider(),
                TextField(
                  controller: _tripController,
                  decoration: InputDecoration(labelText: t(context, 'drivingDetails.trip'), errorText: _tripError),
                  maxLength: 300,
                  onChanged: (_) => setState(() => _tripError = null),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _kmController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: t(context, 'drivingDetails.km'), errorText: _kmError),
                  onChanged: (_) => setState(() => _kmError = null),
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: _save, child: Text(t(context, 'common.save'))),
              ],
            ),
    );
  }

  Widget _buildSaveProgress(BuildContext context) {
    final label = saveXlsxPhaseLabel(context, _savePhase);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(label),
          ],
        ],
      ),
    );
  }
}
