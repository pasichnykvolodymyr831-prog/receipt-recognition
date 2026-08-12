import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/safe_xlsx_write.dart';
import '../xlsx/mileage_report_engine.dart';

/// Manual Driving Details entry (section 9): Date, Trip, KM. Writes to the
/// first free row (2-18) and triggers the Kilometers row recalculation.
class DrivingDetailsScreen extends StatefulWidget {
  final PayrollPeriod period;

  const DrivingDetailsScreen({super.key, required this.period});

  @override
  State<DrivingDetailsScreen> createState() => _DrivingDetailsScreenState();
}

class _DrivingDetailsScreenState extends State<DrivingDetailsScreen> {
  DateTime _date = DateTime.now();
  final _tripController = TextEditingController();
  final _kmController = TextEditingController();
  bool _busy = false;

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
    if (picked != null) setState(() => _date = picked);
  }

  Future<void> _save() async {
    final km = double.tryParse(_kmController.text.trim());
    if (km == null) {
      ScaffoldMessenger.of(context)
          .showSnackBar(SnackBar(content: Text(t(context, 'drivingDetails.invalidKm'))));
      return;
    }
    final trip = _tripController.text.trim();

    setState(() => _busy = true);
    try {
      final fileManager = PeriodFileManager();
      final file = await fileManager.mileageReportFile(widget.period);
      final engine = MileageReportEngine.fromBytes(await file.readAsBytes());

      engine.writeDrivingDetail(date: _date, trip: trip, km: km);
      await writeMileageReportSafely(file, engine.save());

      if (mounted) Navigator.of(context).pop(true);
    } on MileageReportRowsExhaustedException {
      setState(() => _busy = false);
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t(context, 'addReceipt.noRoomTitle')),
            content: Text(t(context, 'drivingDetails.noRoomContent')),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t(context, 'common.ok'))),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'drivingDetails.saveError', {'error': '$e'}))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = '${_date.year}-${_date.month.toString().padLeft(2, '0')}-${_date.day.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'drivingDetails.title'))),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
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
                  decoration: InputDecoration(labelText: t(context, 'drivingDetails.trip')),
                ),
                const SizedBox(height: 8),
                TextField(
                  controller: _kmController,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: InputDecoration(labelText: t(context, 'drivingDetails.km')),
                ),
                const SizedBox(height: 24),
                FilledButton(onPressed: _save, child: Text(t(context, 'common.save'))),
              ],
            ),
    );
  }
}
