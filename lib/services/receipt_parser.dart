/// Pure-Dart parsing of OCR'd receipt text (section 8.3). Operates on plain
/// text lines so it can be unit-tested without a camera or ML Kit.
class ParsedReceipt {
  final DateTime? date;
  final double? subtotal;
  final double? gst;

  const ParsedReceipt({this.date, this.subtotal, this.gst});
}

/// One line of OCR'd text with its vertical position on the page, used to
/// match a label to a value that ended up in a different OCR block on the
/// same printed row (see [_findAmountForLabel]).
class OcrLine {
  final String text;
  final double top;
  final double bottom;

  const OcrLine(this.text, this.top, this.bottom);

  double get centerY => (top + bottom) / 2;
  double get height => bottom - top;
}

const _taxSynonyms = ['gst/hst', 'gst', 'hst', 'sales tax', 'tax'];

/// Parses receipt fields from geometry-aware OCR lines (the real path, fed
/// from ML Kit's [TextLine.boundingBox]).
ParsedReceipt parseReceiptLines(List<OcrLine> lines, {required DateTime today}) {
  final texts = lines.map((l) => l.text).toList();
  return ParsedReceipt(
    date: _findDate(texts, today: today),
    subtotal: _findAmountForLabel(lines, const ['subtotal']),
    gst: _findAmountForLabel(lines, _taxSynonyms),
  );
}

/// Parses receipt fields from plain text lines (used by unit tests, and as
/// a convenience wrapper with no real geometry -- each line only matches
/// itself, i.e. label and amount must be on the same string).
ParsedReceipt parseReceiptText(List<String> lines, {required DateTime today}) {
  final ocrLines = <OcrLine>[
    for (var i = 0; i < lines.length; i++) OcrLine(lines[i], i * 10.0, i * 10.0 + 9),
  ];
  return parseReceiptLines(ocrLines, today: today);
}

/// Finds the label among [lines] (case-insensitive substring match) and
/// returns the first amount found on that same OCR line. If the label's own
/// line has no amount, falls back to the nearest other line (by vertical
/// center) that does -- this covers two-column receipt layouts where ML Kit
/// splits a label and its value, printed on the same row, into separate
/// blocks (see the RONA fixture: "Subtotal:" and "$132.75" land in
/// different blocks despite being on the same printed line).
double? _findAmountForLabel(List<OcrLine> lines, List<String> labels) {
  for (final line in lines) {
    final lower = line.text.toLowerCase();
    if (!labels.any((label) => lower.contains(label))) continue;

    final sameLineAmount = _firstAmountOnLine(line.text);
    if (sameLineAmount != null) return sameLineAmount;

    OcrLine? nearest;
    double? nearestDistance;
    for (final candidate in lines) {
      if (identical(candidate, line)) continue;
      if (_firstAmountOnLine(candidate.text) == null) continue;
      final distance = (candidate.centerY - line.centerY).abs();
      final tolerance = (line.height + candidate.height) / 2 * 0.8;
      if (distance > tolerance) continue;
      if (nearestDistance == null || distance < nearestDistance) {
        nearest = candidate;
        nearestDistance = distance;
      }
    }
    if (nearest != null) return _firstAmountOnLine(nearest.text);
  }
  return null;
}

final _amountPattern = RegExp(r'\d{1,3}(?:,\d{3})*\.\d{2}|\d+\.\d{2}');

double? _firstAmountOnLine(String line) {
  final match = _amountPattern.firstMatch(line);
  if (match == null) return null;
  return double.tryParse(match.group(0)!.replaceAll(',', ''));
}

const _monthNames = {
  'jan': 1, 'feb': 2, 'mar': 3, 'apr': 4, 'may': 5, 'jun': 6,
  'jul': 7, 'aug': 8, 'sep': 9, 'oct': 10, 'nov': 11, 'dec': 12,
};

final _numericDatePattern = RegExp(r'(\d{1,2})[/\-](\d{1,2})[/\-](\d{2,4})');
final _monthNameDatePattern =
    RegExp(r'([A-Za-z]{3,9})\.?\s+(\d{1,2}),?\s+(\d{4})');
final _dayMonthNameDatePattern =
    RegExp(r'(\d{1,2})\s+([A-Za-z]{3,9})\.?,?\s+(\d{4})');

DateTime? _findDate(List<String> lines, {required DateTime today}) {
  for (final line in lines) {
    final monthNameDate = _tryMonthNameDate(line, today);
    if (monthNameDate != null) return monthNameDate;
  }

  for (final line in lines) {
    final numericDate = _tryNumericAmbiguousDate(line, today);
    if (numericDate != null) return numericDate;
  }

  return null;
}

DateTime? _tryMonthNameDate(String line, DateTime today) {
  final m1 = _monthNameDatePattern.firstMatch(line);
  if (m1 != null) {
    final month = _monthNames[m1.group(1)!.toLowerCase().substring(0, 3)];
    final day = int.tryParse(m1.group(2)!);
    final year = int.tryParse(m1.group(3)!);
    final date = _tryBuildDate(year, month, day);
    if (date != null && !date.isAfter(today)) return date;
  }
  final m2 = _dayMonthNameDatePattern.firstMatch(line);
  if (m2 != null) {
    final day = int.tryParse(m2.group(1)!);
    final month = _monthNames[m2.group(2)!.toLowerCase().substring(0, 3)];
    final year = int.tryParse(m2.group(3)!);
    final date = _tryBuildDate(year, month, day);
    if (date != null && !date.isAfter(today)) return date;
  }
  return null;
}

/// Implements the ambiguity-resolution algorithm from section 8.3: for a
/// numeric `a/b/year` date where it's unclear whether `a` is the day or the
/// month, try both interpretations, drop future dates, and only accept the
/// result if exactly one candidate falls within [today-35, today].
DateTime? _tryNumericAmbiguousDate(String line, DateTime today) {
  final match = _numericDatePattern.firstMatch(line);
  if (match == null) return null;

  final a = int.parse(match.group(1)!);
  final b = int.parse(match.group(2)!);
  var year = int.parse(match.group(3)!);
  if (year < 100) year += 2000;

  final candidates = <DateTime>{};
  final asDayMonth = _tryBuildDate(year, b, a); // a=day, b=month
  if (asDayMonth != null) candidates.add(asDayMonth);
  final asMonthDay = _tryBuildDate(year, a, b); // a=month, b=day
  if (asMonthDay != null) candidates.add(asMonthDay);

  final notFuture = candidates.where((d) => !d.isAfter(today)).toList();

  final windowStart = today.subtract(const Duration(days: 35));
  final inWindow = notFuture.where((d) => !d.isBefore(windowStart)).toList();

  if (inWindow.length == 1) return inWindow.single;
  return null;
}

DateTime? _tryBuildDate(int? year, int? month, int? day) {
  if (year == null || month == null || day == null) return null;
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day);
  // DateTime normalizes overflow (e.g. Feb 30 -> Mar 2); reject those.
  if (date.year != year || date.month != month || date.day != day) return null;
  return date;
}
