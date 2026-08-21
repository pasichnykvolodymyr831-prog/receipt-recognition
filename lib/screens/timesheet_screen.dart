import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/safe_xlsx_write.dart';
import '../utils/time_format.dart';
import '../widgets/save_progress_overlay.dart';
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
  final _progress = SaveProgressController();

  @override
  void initState() {
    super.initState();
    _loadFuture = _load();
  }

  @override
  void dispose() {
    _progress.dispose();
    super.dispose();
  }

  Future<void> _load() async {
    final fileManager = PeriodFileManager();
    final file = await fileManager.timesheetFile(widget.period);
    _summary = await readTimesheetSummary(file);
  }

  Future<void> _openDay(int row, DateTime date) async {
    if (_progress.busy) return; // guards against a second tap starting a concurrent write
    final existing = _summary!.daysByRow[row - TimesheetEngine.firstDayRow];
    final result = await Navigator.of(context).push<_DayEditResult>(
      MaterialPageRoute(builder: (context) => _EditDayScreen(date: date, initial: existing)),
    );
    if (result == null) return; // cancelled -- distinct from an explicit "clear the day"
    if (!mounted) return;

    final ok = await _progress.run(
      context,
      (onPhase) async {
        final fileManager = PeriodFileManager();
        final file = await fileManager.timesheetFile(widget.period);
        switch (result) {
          case _DaySaved(:final input):
            await saveTimesheetDay(file, row: row, input: input, onPhase: onPhase);
          case _DayCleared():
            await clearTimesheetDay(file, row: row, onPhase: onPhase);
        }
        _summary = await readTimesheetSummary(file);
      },
      messageFor: (e) => (title: null, message: t(context, 'timesheet.saveError', {'error': '$e'})),
      successMessage: t(context, 'common.saved'),
    );
    // _summary was already refreshed inside the action above on success --
    // this just triggers the rebuild to show it (the overlay's own
    // controller listener doesn't know about this screen's separate state).
    if (ok && mounted) setState(() {});
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

          return SaveProgressOverlay(
            controller: _progress,
            child: ListView.builder(
              itemCount: totalDays + 1,
              itemBuilder: (context, index) {
                if (index == totalDays) {
                  return ListTile(
                    title: Text(t(context, 'timesheet.totalHrs'), style: const TextStyle(fontWeight: FontWeight.bold)),
                    trailing: Text(summary.totalHours.toStringAsFixed(2)),
                  );
                }
                final row = TimesheetEngine.firstDayRow + index;
                final date = widget.period.start.add(Duration(days: index));
                final hours = summary.hoursByRow[index];
                final isWeekend = date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
                final isStat = widget.period.isStatHoliday(date);
                final dateFmt = formatDate(date);

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
          );
        },
      ),
    );
  }
}

/// What closing the per-day editor means: a filled-in day to save, an
/// explicit request to blank the day out (section 10 -- a legitimate action,
/// distinct from cancelling), or `null` (the route's own null, handled by
/// the caller) for "the user backed out without deciding either way".
sealed class _DayEditResult {
  const _DayEditResult();
}

class _DaySaved extends _DayEditResult {
  final TimesheetDayInput input;
  const _DaySaved(this.input);
}

class _DayCleared extends _DayEditResult {
  const _DayCleared();
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

  // Section 10: a day's hours can't be negative or zero -- Finish before
  // Start, or breaks eating the whole span, both silently corrupt H39 if
  // let through.
  String? _hoursError;

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
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        onPicked(picked);
        _hoursError = null;
      });
    }
  }

  TimesheetDayInput get _input => TimesheetDayInput(
        start: _start,
        lunchStart: _lunchStart,
        lunchEnd: _lunchEnd,
        coffeeStart: _hasCoffee ? _coffeeStart : null,
        coffeeEnd: _hasCoffee ? _coffeeEnd : null,
        finish: _finish,
      );

  double get _hours => _input.hours;

  /// Section 10: Finish at or before Start reads as a same-day negative/zero
  /// span here (the app doesn't support a shift crossing midnight in one
  /// row) -- used only to pick a more useful error message, not to compute
  /// hours differently.
  bool get _looksLikeMidnightCrossing => _finish.hour * 60 + _finish.minute <= _start.hour * 60 + _start.minute;

  void _save() {
    final hours = _hours;
    if (hours <= 0) {
      setState(() {
        _hoursError = _looksLikeMidnightCrossing
            ? t(context, 'timesheet.errorMidnightCrossing')
            : t(context, 'timesheet.errorNonPositiveHours');
      });
      return;
    }
    Navigator.of(context).pop(_DaySaved(_input));
  }

  void _clearDay() {
    Navigator.of(context).pop(const _DayCleared());
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = formatDate(widget.date);

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
              // The mounted guard here is load-bearing, not redundant with
              // the one inside _pick: it stops a SECOND showTimePicker call
              // from ever starting with a stale context, not just guarding
              // the setState after it returns.
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
          if (_hoursError != null)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Text(_hoursError!, style: const TextStyle(color: Colors.red)),
            ),
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: Text(t(context, 'common.save'))),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: _clearDay, child: Text(t(context, 'timesheet.clearDay'))),
        ],
      ),
    );
  }
}
