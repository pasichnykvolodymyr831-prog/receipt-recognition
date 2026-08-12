import 'package:excel/excel.dart';

/// Returns the plain text of a cell, or '' if the cell is empty/non-text.
/// Works for [TextCellValue] and falls back to [CellValue.toString] for
/// other populated types so callers can still prefix-match formula/number
/// cells without crashing.
String textOf(CellValue? value) {
  if (value == null) return '';
  if (value is TextCellValue) return value.value.toString();
  return value.toString();
}

/// Returns the numeric value of a cell (Int/Double), or null if the cell
/// is empty or not numeric.
double? numberOf(CellValue? value) {
  if (value is IntCellValue) return value.value.toDouble();
  if (value is DoubleCellValue) return value.value;
  return null;
}

bool isEmptyCell(CellValue? value) {
  if (value == null) return true;
  if (value is TextCellValue) return value.value.toString().trim().isEmpty;
  return false;
}

/// Formats a km total for the "Kilometers (N)" description: whole numbers
/// print without a decimal point, fractional totals keep up to 2 decimals
/// with trailing zeros trimmed.
String formatKmCount(double n) {
  if (n == n.roundToDouble()) {
    return n.toInt().toString();
  }
  var s = n.toStringAsFixed(2);
  s = s.replaceFirst(RegExp(r'0+$'), '');
  s = s.replaceFirst(RegExp(r'\.$'), '');
  return s;
}
