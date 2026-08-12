import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Reads sheet visibility directly from `xl/workbook.xml`, independent of
/// the `excel` package's object model. Used by the integrity checker
/// (section 13) because the `excel` package does not expose a public API
/// for a sheet's hidden/visible state.
///
/// Returns a map of sheet name -> true if hidden (state="hidden" or
/// state="veryHidden"), false otherwise (including sheets with no `state`
/// attribute, which are visible by default per the OOXML spec).
Map<String, bool> readSheetHiddenStates(List<int> xlsxBytes) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  final workbookFile = archive.findFile('xl/workbook.xml');
  if (workbookFile == null) {
    throw const FormatException('xl/workbook.xml not found in archive');
  }
  final content = String.fromCharCodes(workbookFile.content as List<int>);
  final document = XmlDocument.parse(content);

  final result = <String, bool>{};
  for (final sheetNode in document.findAllElements('sheet')) {
    final name = sheetNode.getAttribute('name');
    if (name == null) continue;
    final state = sheetNode.getAttribute('state');
    result[name] = state == 'hidden' || state == 'veryHidden';
  }
  return result;
}
