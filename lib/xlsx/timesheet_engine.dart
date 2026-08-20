import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/material.dart';

import '../models/payroll_period.dart';
import '../utils/time_format.dart';
import 'cell_value_utils.dart';
import 'xlsx_rels_compat.dart';

class TimesheetStructureException implements Exception {
  final String message;
  const TimesheetStructureException(this.message);
  @override
  String toString() => 'TimesheetStructureException: $message';
}

class TimesheetDayInput {
  final TimeOfDay start;
  final TimeOfDay lunchStart;
  final TimeOfDay lunchEnd;
  final TimeOfDay? coffeeStart;
  final TimeOfDay? coffeeEnd;
  final TimeOfDay finish;

  const TimesheetDayInput({
    required this.start,
    required this.lunchStart,
    required this.lunchEnd,
    this.coffeeStart,
    this.coffeeEnd,
    required this.finish,
  });

  double get hours {
    var total = hoursBetween(start, finish);
    total -= hoursBetween(lunchStart, lunchEnd);
    if (coffeeStart != null && coffeeEnd != null) {
      total -= hoursBetween(coffeeStart!, coffeeEnd!);
    }
    return total;
  }
}

/// Read/write engine for the Timesheet workbook's single sheet, implementing
/// the exact cell map and auto-fill rules from sections 6.3 and 10.
class TimesheetEngine {
  static const sheetName = 'Sheet1';

  static const firstDayRow = 8; // Item# 1
  static const lastDayRow = 38; // Item# 31
  static const totalRow = 39;

  final Excel excel;

  TimesheetEngine(this.excel) {
    _assertStructure();
  }

  /// Normalizes package-root-relative `.rels` targets before decoding --
  /// see [MileageReportEngine.fromBytes] for why every `.fromBytes` factory
  /// does this rather than relying on callers to normalize separately.
  factory TimesheetEngine.fromBytes(List<int> bytes) {
    return TimesheetEngine(Excel.decodeBytes(normalizeXlsxRelationshipTargets(Uint8List.fromList(bytes))));
  }

  List<int> save() {
    final bytes = excel.encode();
    if (bytes == null) {
      throw StateError('excel.encode() returned null');
    }
    return bytes;
  }

  void _assertStructure() {
    if (!excel.sheets.containsKey(sheetName)) {
      throw TimesheetStructureException('Sheet "$sheetName" not found');
    }
    final sheet = excel.sheets[sheetName]!;
    final headerRow7 = ['Item#', 'Date', 'Start Time', 'Lunch Break', 'Coffee Break', 'Finish Time', 'Hours', 'Total'];
    for (var col = 0; col < headerRow7.length; col++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 6));
      if (textOf(cell.value).trim().isEmpty) {
        throw TimesheetStructureException(
            'Expected header at row 7 col $col, found empty cell. '
            'The file may have been edited outside the app.');
      }
    }
  }

  Sheet get _sheet => excel.sheets[sheetName]!;

  Data _cell(String a1) => _sheet.cell(CellIndex.indexByString(a1));

  void writeHeader({required String employeeName, required String periodLabel, required String phone}) {
    setCellValue(_sheet, 'C2', TextCellValue(employeeName));
    setCellValue(_sheet, 'C5', TextCellValue(periodLabel));
    setCellValue(_sheet, 'C6', TextCellValue(phone));
  }

  /// Rewrites C2 (employee name) and C6 (phone) on an already-existing file
  /// (Пакет 9: a Settings name/phone change propagates to the current
  /// period's file immediately). Doesn't touch C5 (period label), unlike
  /// [writeHeader], which is only ever called once at creation.
  void updateHeader({required String employeeName, required String phone}) {
    setCellValue(_sheet, 'C2', TextCellValue(employeeName));
    setCellValue(_sheet, 'C6', TextCellValue(phone));
  }

  /// Auto-fills every day of the period starting at row 8 (Item# 1), per
  /// section 10: weekends and STAT holidays are left blank; weekdays get
  /// the standard 8am-4:30pm default with a 12:00-12:30 lunch.
  void autoFillPeriod(PayrollPeriod period) {
    final totalDays = period.end.difference(period.start).inDays + 1;
    for (var offset = 0; offset < totalDays; offset++) {
      final row = firstDayRow + offset;
      if (row > lastDayRow) break;
      final date = period.start.add(Duration(days: offset));

      setCellValue(_sheet, 'B$row', DateCellValue.fromDateTime(date));

      final isWeekend = date.weekday == DateTime.saturday || date.weekday == DateTime.sunday;
      final isStat = period.isStatHoliday(date);
      if (isWeekend || isStat) {
        continue; // C-H stay blank
      }

      setCellValue(_sheet, 'C$row', TextCellValue('8am'));
      setCellValue(_sheet, 'D$row', TextCellValue('1200-1230'));
      setCellValue(_sheet, 'F$row', TextCellValue('430pm'));
      setCellValue(_sheet, 'G$row', const DoubleCellValue(8));
      setCellValue(_sheet, 'H$row', const DoubleCellValue(8));
    }
    recalcTotalHours();
  }

  /// Writes a single day's edited times (section 10, per-day edit form) and
  /// recomputes Hours/Total for that row plus the H39 grand total.
  void writeDay(int row, TimesheetDayInput input) {
    if (row < firstDayRow || row > lastDayRow) {
      throw RangeError.value(row, 'row', 'Must be between $firstDayRow and $lastDayRow');
    }
    setCellValue(_sheet, 'C$row', TextCellValue(formatClockTime(input.start)));
    setCellValue(_sheet, 'D$row', TextCellValue(formatTimeRange(input.lunchStart, input.lunchEnd)));
    if (input.coffeeStart != null && input.coffeeEnd != null) {
      setCellValue(_sheet, 'E$row', TextCellValue(formatTimeRange(input.coffeeStart!, input.coffeeEnd!)));
    } else {
      setCellValue(_sheet, 'E$row', null);
    }
    setCellValue(_sheet, 'F$row', TextCellValue(formatClockTime(input.finish)));

    final hours = input.hours;
    setCellValue(_sheet, 'G$row', DoubleCellValue(hours));
    setCellValue(_sheet, 'H$row', DoubleCellValue(hours));

    recalcTotalHours();
  }

  /// Clears a day's Start/Lunch/Coffee/Finish/Hours/Total (section 10) --
  /// marks the day as not worked. A legitimate, deliberate action (weekend,
  /// STAT, sick day, or a day the user simply didn't work), not an error
  /// case; distinct from [writeDay]'s validation of a filled-in day.
  void clearDay(int row) {
    if (row < firstDayRow || row > lastDayRow) {
      throw RangeError.value(row, 'row', 'Must be between $firstDayRow and $lastDayRow');
    }
    for (final col in ['C', 'D', 'E', 'F', 'G', 'H']) {
      setCellValue(_sheet, '$col$row', null);
    }
    recalcTotalHours();
  }

  /// Reads back the date for [row] (or null if blank), for populating the
  /// day list (section 10).
  DateTime? readDate(int row) {
    final value = _cell('B$row').value;
    if (value is DateCellValue) return value.asDateTimeLocal();
    return null;
  }

  double? readHours(int row) => numberOf(_cell('H$row').value);

  double readTotalHours() => numberOf(_cell('H$totalRow').value) ?? 0;

  /// Reads back a previously-written day's times (section 10: reopening an
  /// already-edited day should show its current values), or null if the
  /// row's times don't parse (blank/weekend/STAT day).
  TimesheetDayInput? readDay(int row) {
    final start = parseClockTime(textOf(_cell('C$row').value));
    final lunch = parseTimeRange(textOf(_cell('D$row').value));
    final finish = parseClockTime(textOf(_cell('F$row').value));
    if (start == null || lunch == null || finish == null) return null;
    final coffee = parseTimeRange(textOf(_cell('E$row').value));
    return TimesheetDayInput(
      start: start,
      lunchStart: lunch.$1,
      lunchEnd: lunch.$2,
      coffeeStart: coffee?.$1,
      coffeeEnd: coffee?.$2,
      finish: finish,
    );
  }

  /// Recomputes H39 as the sum of H8:H38 (a plain number, not a formula --
  /// matches the original template's convention).
  void recalcTotalHours() {
    var total = 0.0;
    for (var row = firstDayRow; row <= lastDayRow; row++) {
      final value = numberOf(_cell('H$row').value);
      if (value != null) total += value;
    }
    if (total == total.roundToDouble()) {
      setCellValue(_sheet, 'H$totalRow', IntCellValue(total.toInt()));
    } else {
      setCellValue(_sheet, 'H$totalRow', DoubleCellValue(total));
    }
  }
}
