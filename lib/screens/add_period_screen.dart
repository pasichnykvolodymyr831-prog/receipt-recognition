import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_repository.dart';

/// The manual "add / edit period" form (section 5). Used both from Settings
/// and as a blocking flow when the user has run past the last known period.
class AddPeriodScreen extends StatefulWidget {
  final PayrollPeriod? existing;
  final (DateTime, DateTime)? suggestedRange;
  final bool blocking;

  /// Called after a successful save. Required when this screen is embedded
  /// directly as a body (the blocking home-screen flow) rather than pushed
  /// as a route, since there's nothing to pop back to in that case.
  final ValueChanged<PayrollPeriod>? onSaved;

  const AddPeriodScreen({
    super.key,
    this.existing,
    this.suggestedRange,
    this.blocking = false,
    this.onSaved,
  });

  @override
  State<AddPeriodScreen> createState() => _AddPeriodScreenState();
}

class _AddPeriodScreenState extends State<AddPeriodScreen> {
  late DateTime _start;
  late DateTime _end;
  late DateTime _dueDate;
  late TimeOfDay _dueTime;
  bool _hasWeekendAltDue = false;
  DateTime? _weekendAltDueDate;
  TimeOfDay _weekendAltDueTime = const TimeOfDay(hour: 8, minute: 30);
  final List<_StatHolidayRow> _statHolidays = [];
  String? _error;
  bool _saving = false;

  @override
  void initState() {
    super.initState();
    final existing = widget.existing;
    if (existing != null) {
      _start = existing.start;
      _end = existing.end;
      _dueDate = DateTime(existing.due.year, existing.due.month, existing.due.day);
      _dueTime = TimeOfDay(hour: existing.due.hour, minute: existing.due.minute);
      _hasWeekendAltDue = existing.weekendAltDue != null;
      if (existing.weekendAltDue != null) {
        _weekendAltDueDate = DateTime(
            existing.weekendAltDue!.year, existing.weekendAltDue!.month, existing.weekendAltDue!.day);
        _weekendAltDueTime = TimeOfDay(hour: existing.weekendAltDue!.hour, minute: existing.weekendAltDue!.minute);
      }
      for (final h in existing.statHolidays) {
        _statHolidays.add(_StatHolidayRow(name: h.name, date: h.date));
      }
    } else {
      final suggested = widget.suggestedRange;
      _start = suggested?.$1 ?? DateTime.now();
      _end = suggested?.$2 ?? DateTime.now().add(const Duration(days: 14));
      _dueDate = _end;
      _dueTime = const TimeOfDay(hour: 16, minute: 30);
    }
  }

  Future<void> _pickDate(DateTime initial, void Function(DateTime) onPicked) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (picked != null) setState(() => onPicked(picked));
  }

  Future<void> _pickTime(TimeOfDay initial, void Function(TimeOfDay) onPicked) async {
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (picked != null) setState(() => onPicked(picked));
  }

  DateTime get _dueDateTime =>
      DateTime(_dueDate.year, _dueDate.month, _dueDate.day, _dueTime.hour, _dueTime.minute);

  DateTime? get _weekendAltDueDateTime {
    if (!_hasWeekendAltDue || _weekendAltDueDate == null) return null;
    return DateTime(_weekendAltDueDate!.year, _weekendAltDueDate!.month, _weekendAltDueDate!.day,
        _weekendAltDueTime.hour, _weekendAltDueTime.minute);
  }

  String? _validate() {
    if (_end.isBefore(_start)) return t(context, 'addPeriod.errorEndBeforeStart');
    final dueDay = DateTime(_dueDateTime.year, _dueDateTime.month, _dueDateTime.day);
    final startDay = DateTime(_start.year, _start.month, _start.day);
    final endDay = DateTime(_end.year, _end.month, _end.day);
    if (dueDay.isBefore(startDay) || dueDay.isAfter(endDay)) {
      return t(context, 'addPeriod.errorDueOutOfRange');
    }
    for (final h in _statHolidays) {
      if (h.date == null || h.name.trim().isEmpty) return t(context, 'addPeriod.errorStatIncomplete');
      final d = DateTime(h.date!.year, h.date!.month, h.date!.day);
      if (d.isBefore(startDay) || d.isAfter(endDay)) {
        return t(context, 'addPeriod.errorStatOutOfRange', {'name': h.name});
      }
    }
    return null;
  }

  Future<void> _save() async {
    final error = _validate();
    if (error != null) {
      setState(() => _error = error);
      return;
    }
    setState(() {
      _saving = true;
      _error = null;
    });

    final period = PayrollPeriod(
      key: widget.existing?.key ?? PayrollPeriod.newKey(),
      start: _start,
      end: _end,
      due: _dueDateTime,
      weekendAltDue: _weekendAltDueDateTime,
      statHolidays: _statHolidays
          .map((h) => StatHoliday(name: h.name.trim(), date: h.date!))
          .toList(),
    );

    final repo = PeriodRepository();
    if (widget.existing != null) {
      await repo.updatePeriod(period);
    } else {
      await repo.addPeriod(period);
    }

    if (!mounted) return;
    widget.onSaved?.call(period);
    if (Navigator.of(context).canPop()) {
      Navigator.of(context).pop(period);
    }
  }

  @override
  Widget build(BuildContext context) {
    final dateFmt = (DateTime d) => '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';

    return PopScope(
      canPop: !widget.blocking,
      child: Scaffold(
        appBar: AppBar(
          title: Text(widget.existing != null ? t(context, 'addPeriod.titleEdit') : t(context, 'addPeriod.titleAdd')),
          automaticallyImplyLeading: !widget.blocking,
        ),
        body: ListView(
          padding: const EdgeInsets.all(16),
          children: [
            if (widget.blocking)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(
                  t(context, 'addPeriod.blockingBanner'),
                  style: const TextStyle(fontWeight: FontWeight.bold),
                ),
              ),
            if (_error != null)
              Padding(
                padding: const EdgeInsets.only(bottom: 16),
                child: Text(_error!, style: const TextStyle(color: Colors.red)),
              ),
            ListTile(
              title: Text(t(context, 'addPeriod.periodStart')),
              subtitle: Text(dateFmt(_start)),
              onTap: () => _pickDate(_start, (d) => _start = d),
            ),
            ListTile(
              title: Text(t(context, 'addPeriod.periodEnd')),
              subtitle: Text(dateFmt(_end)),
              onTap: () => _pickDate(_end, (d) => _end = d),
            ),
            const Divider(),
            ListTile(
              title: Text(t(context, 'addPeriod.dueDate')),
              subtitle: Text(dateFmt(_dueDate)),
              onTap: () => _pickDate(_dueDate, (d) => _dueDate = d),
            ),
            ListTile(
              title: Text(t(context, 'addPeriod.dueTime')),
              subtitle: Text(_dueTime.format(context)),
              onTap: () => _pickTime(_dueTime, (t) => _dueTime = t),
            ),
            const Divider(),
            SwitchListTile(
              title: Text(t(context, 'addPeriod.weekendToggle')),
              value: _hasWeekendAltDue,
              onChanged: (v) => setState(() {
                _hasWeekendAltDue = v;
                _weekendAltDueDate ??= _end.add(const Duration(days: 2));
              }),
            ),
            if (_hasWeekendAltDue) ...[
              ListTile(
                title: Text(t(context, 'addPeriod.weekendDueDate')),
                subtitle: Text(dateFmt(_weekendAltDueDate!)),
                onTap: () => _pickDate(_weekendAltDueDate!, (d) => _weekendAltDueDate = d),
              ),
              ListTile(
                title: Text(t(context, 'addPeriod.weekendDueTime')),
                subtitle: Text(_weekendAltDueTime.format(context)),
                onTap: () => _pickTime(_weekendAltDueTime, (t) => _weekendAltDueTime = t),
              ),
            ],
            const Divider(),
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Text(t(context, 'addPeriod.statHolidays'), style: const TextStyle(fontWeight: FontWeight.bold)),
                IconButton(
                  icon: const Icon(Icons.add),
                  onPressed: () => setState(() => _statHolidays.add(_StatHolidayRow())),
                ),
              ],
            ),
            for (var i = 0; i < _statHolidays.length; i++) _buildStatHolidayRow(i, dateFmt),
            const SizedBox(height: 24),
            FilledButton(
              onPressed: _saving ? null : _save,
              child: _saving ? const CircularProgressIndicator() : Text(t(context, 'common.save')),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildStatHolidayRow(int index, String Function(DateTime) dateFmt) {
    final row = _statHolidays[index];
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Row(
        children: [
          Expanded(
            child: TextFormField(
              initialValue: row.name,
              decoration: InputDecoration(labelText: t(context, 'addPeriod.name')),
              onChanged: (v) => row.name = v,
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: () => _pickDate(row.date ?? _start, (d) => setState(() => row.date = d)),
            child: Text(row.date != null ? dateFmt(row.date!) : t(context, 'addPeriod.pickDate')),
          ),
          IconButton(
            icon: const Icon(Icons.delete_outline),
            onPressed: () => setState(() => _statHolidays.removeAt(index)),
          ),
        ],
      ),
    );
  }
}

class _StatHolidayRow {
  String name;
  DateTime? date;
  _StatHolidayRow({this.name = '', this.date});
}
