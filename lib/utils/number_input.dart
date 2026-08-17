/// Parses a number a human typed into a manual-entry field (Subtotal, GST,
/// KM, the $/km rate) -- section 2: independent of the app's UI language,
/// both "." and "," must work as the decimal separator ("5.29" and "5,29"
/// are the same number). This is purely a screen-input concern: numbers
/// inside the xlsx file itself are always stored with "." (OOXML convention,
/// unaffected by locale) regardless of what the user typed.
double? parseDecimal(String text) {
  final normalized = text.trim().replaceAll(',', '.');
  if (normalized.isEmpty) return null;
  return double.tryParse(normalized);
}

/// Rounds [value] to 2 decimal places (sections 8/9/13.7: Subtotal, GST, KM,
/// and Travel must never carry a longer tail into the file than the cell's
/// own `#,##0.00` display -- otherwise the visible total and the stored sum
/// silently disagree). Multiplies into an integer before rounding rather
/// than going through [double.toStringAsFixed], which sidesteps the
/// classic float-tail case (0.1 + 0.2 == 0.30000000000000004) instead of
/// just formatting over it.
double round2(double value) => (value * 100).round() / 100;
