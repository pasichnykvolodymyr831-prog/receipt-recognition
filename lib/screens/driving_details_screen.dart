import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/mileage_cycle.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
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

  /// Resolved once in [initState] and gates the whole screen (not just the
  /// moment of saving) -- so the user doesn't fill in Trip/KM only to
  /// discover at Save time that [widget.period] isn't paired into a
  /// Mileage cycle yet (`MileageCycle`, whimsical-booping-salamander.md
  /// Пакет 3).
  late Future<MileageCycle?> _cycleFuture;

  @override
  void initState() {
    super.initState();
    _cycleFuture = _resolveCycle();
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

  Future<MileageCycle?> _resolveCycle() async {
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    return periodRepo.mileageCycleFor(widget.period, periods);
  }

  Future<void> _pickDate() async {
    // Already resolved (and non-null -- the screen is gated on it in
    // build()) by the time the date picker is reachable; awaiting the same
    // Future again just returns the cached result, no re-resolve. Bounded
    // by the whole CYCLE's range (not just widget.period's own 2 weeks) --
    // Driving Details entries all land in the one shared Mileage file, so a
    // trip on any day of either half is legitimate here.
    final cycle = (await _cycleFuture)!;
    if (!mounted) return;
    final picked = await showDatePicker(
      context: context,
      initialDate: _date,
      firstDate: cycle.start,
      lastDate: cycle.end,
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
      // Already resolved (and non-null -- the screen is gated on it in
      // build()) by the time Save is reachable; awaiting the same Future
      // again just returns the cached result, no re-resolve.
      final cycle = (await _cycleFuture)!;
      final fileManager = PeriodFileManager();
      final file = await fileManager.mileageReportFile(cycle);
      final settings = await SettingsRepository().load();
      void onPhase(SaveXlsxPhase phase) {
        if (mounted) setState(() => _savePhase = phase);
      }

      // Section 6.2's priority rule uses the CYCLE's own rate (fixed on its
      // opening half, see MileageCycle.kmRate), not widget.period.kmRate --
      // that field is no longer meaningful for Mileage on the second-half
      // period once a cycle is formed.
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
          periodKmRate: cycle.kmRate,
          settingsDefaultRate: settings.kmRate,
          onPhase: onPhase,
        );
      } else {
        await saveMileageDrivingDetail(
          file,
          date: _date,
          trip: trip,
          km: km,
          periodKmRate: cycle.kmRate,
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
      body: FutureBuilder<MileageCycle?>(
        future: _cycleFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          if (snapshot.data == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t(context, 'mileageCycle.notReadyMessage'), textAlign: TextAlign.center),
              ),
            );
          }
          return _busy
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
                      decoration:
                          InputDecoration(labelText: t(context, 'drivingDetails.trip'), errorText: _tripError),
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
                );
        },
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
