import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
import '../services/settings_repository.dart';
import '../utils/number_input.dart';
import '../utils/time_format.dart';
import '../xlsx/mileage_report_engine.dart';

/// The manual "add / edit period" form (section 5). Used both from Settings
/// and as a blocking flow when the user has run past the last known period.
class AddPeriodScreen extends StatefulWidget {
  final PayrollPeriod? existing;
  final (DateTime, DateTime)? suggestedRange;
  final bool blocking;

  /// Every other known period (section 5: a new/edited period must not
  /// overlap any of them). Includes [existing] itself when editing --
  /// [_validate] excludes it from the overlap check by key.
  final List<PayrollPeriod> existingPeriods;

  /// Called after a successful save. Required when this screen is embedded
  /// directly as a body (the blocking home-screen flow) rather than pushed
  /// as a route, since there's nothing to pop back to in that case.
  final ValueChanged<PayrollPeriod>? onSaved;

  const AddPeriodScreen({
    super.key,
    this.existing,
    this.suggestedRange,
    this.blocking = false,
    required this.existingPeriods,
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
  final _kmRateController = TextEditingController();
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
      // Blank is legal here (section 5) and means "no rate of its own --
      // use the Settings default" -- unlike Settings' own rate field.
      _kmRateController.text = existing.kmRate?.toString() ?? '';
    } else {
      final suggested = widget.suggestedRange;
      _start = suggested?.$1 ?? DateTime.now();
      _end = suggested?.$2 ?? DateTime.now().add(const Duration(days: 14));
      _dueDate = _end;
      _dueTime = const TimeOfDay(hour: 16, minute: 30);
    }
  }

  @override
  void dispose() {
    _kmRateController.dispose();
    super.dispose();
  }

  Future<void> _pickDate(DateTime initial, void Function(DateTime) onPicked) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: initial,
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (!mounted) return;
    if (picked != null) setState(() => onPicked(picked));
  }

  Future<void> _pickTime(TimeOfDay initial, void Function(TimeOfDay) onPicked) async {
    final picked = await showTimePicker(context: context, initialTime: initial);
    if (!mounted) return;
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

    final startDay = DateTime(_start.year, _start.month, _start.day);
    final endDay = DateTime(_end.year, _end.month, _end.day);

    // Section 5: real periods run 15-16 days; this only catches a date typo
    // off by a month/year, not a limit on the employer's own schedule.
    final lengthDays = endDay.difference(startDay).inDays + 1;
    if (lengthDays < 7 || lengthDays > 40) {
      return t(context, 'addPeriod.errorLength');
    }

    final dueDay = DateTime(_dueDateTime.year, _dueDateTime.month, _dueDateTime.day);
    if (dueDay.isBefore(startDay) || dueDay.isAfter(endDay)) {
      return t(context, 'addPeriod.errorDueOutOfRange');
    }

    final statDates = <DateTime>{};
    for (final h in _statHolidays) {
      if (h.date == null || h.name.trim().isEmpty) return t(context, 'addPeriod.errorStatIncomplete');
      final d = DateTime(h.date!.year, h.date!.month, h.date!.day);
      if (d.isBefore(startDay) || d.isAfter(endDay)) {
        return t(context, 'addPeriod.errorStatOutOfRange', {'name': h.name});
      }
      if (!statDates.add(d)) {
        // Two STAT rows on the same date is a typo (duplicate entry), not
        // two holidays landing on the same day.
        return t(context, 'addPeriod.errorStatDuplicate');
      }
    }

    // Section 5: a new/edited period must not overlap any existing one --
    // a gap between periods is fine (they may be added out of order), only
    // overlap is blocked. Excludes the period being edited itself by key.
    for (final other in widget.existingPeriods) {
      if (widget.existing != null && other.key == widget.existing!.key) continue;
      final otherStart = DateTime(other.start.year, other.start.month, other.start.day);
      final otherEnd = DateTime(other.end.year, other.end.month, other.end.day);
      final overlaps = !endDay.isBefore(otherStart) && !otherEnd.isBefore(startDay);
      if (overlaps) {
        return t(context, 'addPeriod.errorOverlap');
      }
    }

    // Section 5: blank is legal here (means "use the Settings default") --
    // unlike Settings' own rate field, only a non-blank value is checked
    // for being > 0.
    final rateText = _kmRateController.text.trim();
    if (rateText.isNotEmpty) {
      final rate = parseDecimal(rateText);
      if (rate == null || rate <= 0) {
        return t(context, 'addPeriod.errorKmRate');
      }
    }

    return null;
  }

  /// The rate to save for this period: null if the field was left blank
  /// (section 5), otherwise the parsed value. Only call after [_validate]
  /// has confirmed the field is either blank or a valid positive number.
  double? get _kmRate {
    final rateText = _kmRateController.text.trim();
    return rateText.isEmpty ? null : parseDecimal(rateText);
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

    try {
      final period = PayrollPeriod(
        key: widget.existing?.key ?? PayrollPeriod.newKey(),
        start: _start,
        end: _end,
        due: _dueDateTime,
        weekendAltDue: _weekendAltDueDateTime,
        statHolidays: _statHolidays
            .map((h) => StatHoliday(name: h.name.trim(), date: h.date!))
            .toList(),
        kmRate: _kmRate,
      );

      // Section 6.2, second rate-change path: editing an existing period's
      // own rate field updates G1 + Travel in THAT period's file
      // specifically (including an archival one) -- distinct from the
      // Settings-default path (settings_screen.dart), which only ever
      // touches the current period. A cleared field (back to "use the
      // default") still needs G1 updated -- otherwise it would keep
      // whatever explicit rate was there before, permanently, since a
      // filled G1 is normally authoritative. The file write happens BEFORE
      // the period-repo persist below so a failed file write can never
      // leave period.kmRate and the file's G1 silently diverged (section
      // 6.2: "never only one of the two").
      final oldRate = widget.existing?.kmRate;
      final newRate = period.kmRate;
      final rateChanged = widget.existing != null &&
          ((oldRate == null) != (newRate == null) ||
              (oldRate != null && newRate != null && !MileageReportEngine.ratesEqual(oldRate, newRate)));
      if (rateChanged) {
        final effectiveRate = newRate ?? (await SettingsRepository().load()).kmRate;
        // TODO(whimsical-booping-salamander.md, Пакет 5): this still writes
        // the rate straight into the edited period's Mileage cycle file (if
        // any) -- the plan's "changes always apply from next cycle only,
        // with a warning" behavior, and disabling this field for "9-23"
        // periods, aren't implemented yet.
        //
        // Resolves the cycle against widget.existingPeriods with THIS
        // period's own fresh (possibly just-edited) dates substituted in --
        // not the stale pre-edit copy that list still carries under the
        // same key -- so a date edit that changes which half [period] is
        // (or its pairing) is reflected immediately, not one save behind.
        final periodsForCycle = [
          for (final p in widget.existingPeriods)
            if (p.key != period.key) p,
          period,
        ];
        final cycle = PeriodRepository().mileageCycleFor(period, periodsForCycle);
        await PeriodFileManager().writeRateIfFileExists(cycle, effectiveRate);
      }

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
    } on MileageReportStructureException {
      if (mounted) setState(() => _error = t(context, 'mileageReport.rateChangeStructureError'));
    } on MileageReportRowOccupiedException {
      if (mounted) setState(() => _error = t(context, 'mileageReport.rateChangeRowOccupiedError'));
    } catch (e) {
      if (mounted) setState(() => _error = t(context, 'addPeriod.saveError', {'error': '$e'}));
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
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
              subtitle: Text(formatDate(_start)),
              onTap: () => _pickDate(_start, (d) => _start = d),
            ),
            ListTile(
              title: Text(t(context, 'addPeriod.periodEnd')),
              subtitle: Text(formatDate(_end)),
              onTap: () => _pickDate(_end, (d) => _end = d),
            ),
            const Divider(),
            ListTile(
              title: Text(t(context, 'addPeriod.dueDate')),
              subtitle: Text(formatDate(_dueDate)),
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
                subtitle: Text(formatDate(_weekendAltDueDate!)),
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
            for (var i = 0; i < _statHolidays.length; i++) _buildStatHolidayRow(i, formatDate),
            const Divider(),
            Text(t(context, 'addPeriod.kmRate'), style: const TextStyle(fontWeight: FontWeight.bold)),
            const SizedBox(height: 8),
            TextField(
              controller: _kmRateController,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: InputDecoration(
                labelText: t(context, 'addPeriod.kmRateLabel'),
                hintText: t(context, 'addPeriod.kmRateHint'),
              ),
            ),
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
            child: Text(row.date != null ? formatDate(row.date!) : t(context, 'addPeriod.pickDate')),
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
