import 'package:excel/excel.dart';

/// Writes [value] to the cell at [a1] on [sheet] without losing the cell's
/// existing style (border, font, number_format).
///
/// The `excel` package (v4) always resets a cell to a brand-new default
/// [CellStyle] as a side effect of writing its value -- see `Sheet._putData`,
/// which unconditionally does `cell._cellStyle = CellStyle(...)` before the
/// value assignment returns. There is no package API to set a value without
/// touching style, so every write in this app must go through here: capture
/// the style beforehand, write the value, then reapply the captured style.
void setCellValue(Sheet sheet, String a1, CellValue? value) {
  final cell = sheet.cell(CellIndex.indexByString(a1));
  final style = cell.cellStyle;
  cell.value = value;
  if (style != null) {
    cell.cellStyle = style;
  }
}

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

/// Returns the cell's date, or null if the cell is empty or not a date.
DateTime? dateOf(CellValue? value) {
  if (value is DateCellValue) return value.asDateTimeLocal();
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
