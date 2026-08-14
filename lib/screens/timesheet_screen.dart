import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/safe_xlsx_write.dart';
import '../xlsx/timesheet_engine.dart';

/// Timesheet day list + per-day edit (section 10). Shows the auto-filled
/// days for the period; tapping one opens the Start/Lunch/Coffee/Finish
/// editor, which recomputes Hours/Total automatically.
class TimesheetScreen extends StatefulWidget {
  final PayrollPeriod period;

  const TimesheetScreen({super.key, required this.period});

  @override
  State<TimesheetScreen> createState() => _TimesheetScreenState();
}

class _TimesheetScreenState extends State<TimesheetScreen> {
  late Future<void> _loadFuture;
  TimesheetSummary? _summary;
  bool _busy = false;
  SaveXlsxPhase? _savePhase;

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  Future<void> _load() async {
    final fileManager = PeriodFileManager();
    final file = await fileManager.timesheetFile(widget.period);
    _summary = await readTimesheetSummary(file);
  }

  Future<void> _openDay(int row, DateTime date) async {
    if (_busy) return; // guards against a second tap starting a concurrent write
    final existing = _summary!.daysByRow[row - TimesheetEngine.firstDayRow];
    final result = await Navigator.of(context).push<TimesheetDayInput>(
      MaterialPageRoute(builder: (context) => _EditDayScreen(date: date, initial: existing)),
    );
    if (result == null) return;

    setState(() {
      _busy = true;
      _savePhase = SaveXlsxPhase.reading;
    });
    try {
      final fileManager = PeriodFileManager();
      final file = await fileManager.timesheetFile(widget.period);
      await saveTimesheetDay(
        file,
        row: row,
        input: result,
        onPhase: (phase) {
          if (mounted) setState(() => _savePhase = phase);
        },
      );
      _summary = await readTimesheetSummary(file);
    } catch (e) {
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'drivingDetails.saveError', {'error': '$e'}))));
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'timesheet.title'))),
      body: FutureBuilder<void>(
        future: _loadFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          final summary = _summary!;
          final totalDays = widget.period.end.difference(widget.period.start).inDays + 1;

          return Stack(
            children: [
              AbsorbPointer(
                absorbing: _busy,
                child: ListView.builder(
                  itemCount: totalDays + 1,
                  itemBuilder: (context, index) {
                    if (index == totalDays) {
                      return ListTile(
                        title:
                            Text(t(context, 'timesheet.totalHrs'), style: const TextStyle(fontWeight: FontWeight.bold)),
                        trailing: Text(summary.totalHours.toStringAsFixed(2)),
                      );
                    }
                    final row = TimesheetEngine.firstDayRow + index;
                    final date = widget.period.start.add(Duration(days: index));
                    final hours = summary.hoursByRow[index];
                    final isWeekend = date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
                    final isStat = widget.period.isStatHoliday(date);
                    final dateFmt =
                        '${date.year}-${date.month.toString().padLeft(2, '0')}-${date.day.toString().padLeft(2, '0')}';

                    return ListTile(
                      title: Text(dateFmt),
                      subtitle: isStat
                          ? Text(t(context, 'timesheet.statHoliday'))
                          : (isWeekend ? Text(t(context, 'timesheet.weekend')) : null),
                      trailing: Text(hours != null ? '${hours.toStringAsFixed(2)}h' : '—'),
                      onTap: () => _openDay(row, date),
                    );
                  },
                ),
              ),
              if (_busy) _buildSaveProgressOverlay(context),
            ],
          );
        },
      ),
    );
  }

  Widget _buildSaveProgressOverlay(BuildContext context) {
    final label = saveXlsxPhaseLabel(context, _savePhase);
    return Positioned.fill(
      child: ColoredBox(
        color: Theme.of(context).scaffoldBackgroundColor.withValues(alpha: 0.85),
        child: Center(
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
        ),
      ),
    );
  }
}

class _EditDayScreen extends StatefulWidget {
  final DateTime date;
  final TimesheetDayInput? initial;

  const _EditDayScreen({required this.date, this.initial});

  @override
  State<_EditDayScreen> createState() => _EditDayScreenState();
}

class _EditDayScreenState extends State<_EditDayScreen> {
  late TimeOfDay _start;
  late TimeOfDay _lunchStart;
  late TimeOfDay _lunchEnd;
  bool _hasCoffee = false;
  TimeOfDay? _coffeeStart;
  TimeOfDay? _coffeeEnd;
  late TimeOfDay _finish;

  @override
  void initState() {
    super.initState();
    final initial = widget.initial;
    _start = initial?.start ?? const TimeOfDay(hour: 8, minute: 0);
    _lunchStart = initial?.lunchStart ?? const TimeOfDay(hour: 12, minute: 0);
    _lunchEnd = initial?.lunchEnd ?? const TimeOfDay(hour: 12, minute: 30);
    _finish = initial?.finish ?? const TimeOfDay(hour: 16, minute: 30);
    if (initial?.coffeeStart != null && initial?.coffeeEnd != null) {
      _hasCoffee = true;
      _coffeeStart = initial!.coffeeStart;
      _coffeeEnd = initial.coffeeEnd;
    }
  }

  Future<void> _pick(TimeOfDay initial, void Function(TimeOfDay) onPicked) async {
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) setState(() => onPicked(picked));
  }

  double get _hours {
    final input = TimesheetDayInput(
      start: _start,
      lunchStart: _lunchStart,
      lunchEnd: _lunchEnd,
      coffeeStart: _hasCoffee ? _coffeeStart : null,
      coffeeEnd: _hasCoffee ? _coffeeEnd : null,
      finish: _finish,
    );
    return input.hours;
  }

  void _save() {
    Navigator.of(context).pop(TimesheetDayInput(
      start: _start,
      lunchStart: _lunchStart,
      lunchEnd: _lunchEnd,
      coffeeStart: _hasCoffee ? _coffeeStart : null,
      coffeeEnd: _hasCoffee ? _coffeeEnd : null,
      finish: _finish,
    ));
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt =
        '${widget.date.year}-${widget.date.month.toString().padLeft(2, '0')}-${widget.date.day.toString().padLeft(2, '0')}';

    return Scaffold(
      appBar: AppBar(title: Text(dateFmt)),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          ListTile(
            title: Text(t(context, 'timesheet.startTime')),
            subtitle: Text(_start.format(context)),
            onTap: () => _pick(_start, (t) => _start = t),
          ),
          ListTile(
            title: Text(t(context, 'timesheet.lunchBreak')),
            subtitle: Text('${_lunchStart.format(context)} - ${_lunchEnd.format(context)}'),
            onTap: () async {
              await _pick(_lunchStart, (t) => _lunchStart = t);
              if (mounted) await _pick(_lunchEnd, (t) => _lunchEnd = t);
            },
          ),
          SwitchListTile(
            title: Text(t(context, 'timesheet.coffeeBreak')),
            value: _hasCoffee,
            onChanged: (v) => setState(() {
              _hasCoffee = v;
              _coffeeStart ??= const TimeOfDay(hour: 10, minute: 0);
              _coffeeEnd ??= const TimeOfDay(hour: 10, minute: 15);
            }),
          ),
          if (_hasCoffee)
            ListTile(
              title: Text(t(context, 'timesheet.coffeeBreak')),
              subtitle: Text('${_coffeeStart!.format(context)} - ${_coffeeEnd!.format(context)}'),
              onTap: () async {
                await _pick(_coffeeStart!, (t) => _coffeeStart = t);
                if (mounted) await _pick(_coffeeEnd!, (t) => _coffeeEnd = t);
              },
            ),
          ListTile(
            title: Text(t(context, 'timesheet.finishTime')),
            subtitle: Text(_finish.format(context)),
            onTap: () => _pick(_finish, (t) => _finish = t),
          ),
          const Divider(),
          ListTile(
            title: Text(t(context, 'timesheet.hours'), style: const TextStyle(fontWeight: FontWeight.bold)),
            trailing: Text(_hours.toStringAsFixed(2)),
          ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: Text(t(context, 'common.save'))),
        ],
      ),
    );
  }
}
