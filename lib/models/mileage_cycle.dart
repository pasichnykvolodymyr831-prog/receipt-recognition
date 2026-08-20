import 'payroll_period.dart';

/// A computed (never persisted) pairing of two consecutive [PayrollPeriod]s
/// that together make up one 4-week Mileage Report cycle: the "24th-8th"
/// [firstHalf] plus the "9th-23rd" [secondHalf] that starts the very next
/// day after it ends. Accounting accepts Timesheet every 2 weeks (unchanged)
/// but Mileage Report only every 4 weeks, as a single file covering both
/// halves.
///
/// The $/km rate for the whole cycle lives on [firstHalf] -- [secondHalf]'s
/// own `kmRate` field is never consulted for Mileage purposes once a cycle
/// is formed (see Пакет 5: rate changes only take effect starting the next
/// cycle, an already-started file is never rewritten retroactively).
class MileageCycle {
  final PayrollPeriod firstHalf;
  final PayrollPeriod secondHalf;

  const MileageCycle({required this.firstHalf, required this.secondHalf});

  DateTime get start => firstHalf.start;
  DateTime get end => secondHalf.end;
  DateTime get due => secondHalf.due;

  /// Same `<start>_<end>` shape as [PayrollPeriod.fileId] -- the existing
  /// filename regex in `findPeriodFile` needs no changes to also match
  /// cycle-named Mileage files.
  String get fileId => '${_dateOnly(start)}_${_dateOnly(end)}';

  /// The cycle's $/km rate, fixed on [firstHalf] for its whole lifetime.
  double? get kmRate => firstHalf.kmRate;
}

String _dateOnly(DateTime d) =>
    '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
