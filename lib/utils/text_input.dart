/// Normalizes free text the user types into Description (section 8) or Trip
/// (section 9) before it's written to a cell: trims surrounding whitespace,
/// collapses embedded line breaks to a single space (multi-line text breaks
/// the printed report's row height and layout), and caps the length as a
/// defense-in-depth backstop. The primary length limit belongs on the input
/// field itself (`TextField(maxLength: ...)`) so the user sees it as they
/// type -- silently truncating only at save time would throw away text
/// they never got to see was cut.
String sanitizeFreeText(String raw, {int maxLength = 300}) {
  var s = raw.trim().replaceAll(RegExp(r'[\r\n]+'), ' ');
  if (s.length > maxLength) s = s.substring(0, maxLength);
  return s;
}
