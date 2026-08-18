// Regression test for the real "Excel repair-on-open" bug found on a real
// device Timesheet file: `_patchCellStyles` appended a freshly-built
// `<alignment>` child to the END of a cloned `<xf>`, which lands AFTER an
// existing `<protection>` child on any cell whose current xf already had
// one. CT_Xf's child sequence is strictly ordered (alignment, protection,
// extLst) per the real ECMA-376 SpreadsheetML schema -- an out-of-order
// `<alignment>` produced schema-invalid `<xf>` elements that every lenient
// parser (openpyxl, the `excel` package's own reader, even lxml's
// well-formedness check) tolerated silently, but that real Microsoft
// Excel's stricter OOXML validator rejected, forcing a "repair" on open
// that discarded styles.xml. Confirmed against the real XSD schema
// (t-yuki/ooxml-xsd mirror of ECMA-376) during the original investigation;
// this test only needs to assert the child order, not re-validate the
// full schema, to catch a regression.
import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:expenseflow/xlsx/raw_style_patch.dart';

Uint8List _buildMinimalXlsx(String stylesXml, String sheetXml) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add(
    'xl/workbook.xml',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
    'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
    '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>',
  );
  add(
    'xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
    'Target="worksheets/sheet1.xml"/></Relationships>',
  );
  add('xl/styles.xml', stylesXml);
  add('xl/worksheets/sheet1.xml', sheetXml);

  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

XmlDocument _stylesOf(Uint8List xlsxBytes) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  final file = archive.findFile('xl/styles.xml')!;
  return XmlDocument.parse(utf8.decode(file.content as List<int>));
}

XmlDocument _sheetOf(Uint8List xlsxBytes) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  final file = archive.findFile('xl/worksheets/sheet1.xml')!;
  return XmlDocument.parse(utf8.decode(file.content as List<int>));
}

XmlDocument _workbookOf(Uint8List xlsxBytes) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  final file = archive.findFile('xl/workbook.xml')!;
  return XmlDocument.parse(utf8.decode(file.content as List<int>));
}

const _minimalFontsFillsBorders = '<fonts count="1"><font/></fonts>'
    '<fills count="1"><fill/></fills>'
    '<borders count="1"><border/></borders>';

const _minimalSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '<sheetData><row r="1"><c r="A1" s="0"/></row></sheetData></worksheet>';

const _minimalStyles = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
    '$_minimalFontsFillsBorders'
    '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
    '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellXfs>'
    '</styleSheet>';

Uint8List _buildXlsxWithWorkbook(String workbookXml, String sheetXml) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('xl/workbook.xml', workbookXml);
  add(
    'xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
    'Target="worksheets/sheet1.xml"/></Relationships>',
  );
  add('xl/styles.xml', _minimalStyles);
  add('xl/worksheets/sheet1.xml', sheetXml);

  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

Uint8List _buildXlsxWithWorkbookAndStyles(String workbookXml, String sheetXml, String stylesXml) {
  final archive = Archive();
  void add(String name, String content) {
    final bytes = utf8.encode(content);
    archive.addFile(ArchiveFile(name, bytes.length, bytes));
  }

  add('xl/workbook.xml', workbookXml);
  add(
    'xl/_rels/workbook.xml.rels',
    '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
    '<Relationships xmlns="http://schemas.openxmlformats.org/package/2006/relationships">'
    '<Relationship Id="rId1" Type="http://schemas.openxmlformats.org/officeDocument/2006/relationships/worksheet" '
    'Target="worksheets/sheet1.xml"/></Relationships>',
  );
  add('xl/styles.xml', stylesXml);
  add('xl/worksheets/sheet1.xml', sheetXml);

  final encoded = ZipEncoder().encode(archive);
  return Uint8List.fromList(encoded!);
}

void main() {
  test('a repaired <xf> keeps <alignment> before an existing <protection> child (CT_Xf schema order)', () {
    // Template wants left/bottom alignment on A1.
    final template = _buildMinimalXlsx(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '$_minimalFontsFillsBorders'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" applyAlignment="1">'
      '<alignment horizontal="left" vertical="bottom"/></xf></cellXfs>'
      '</styleSheet>',
      _minimalSheet,
    );
    // "Encoded" output: A1's current xf already carries a <protection>
    // child (as real Timesheet cells commonly do) and no alignment at all
    // -- exactly the shape that triggers needsAlign.
    final encoded = _buildMinimalXlsx(
      '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
      '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
      '$_minimalFontsFillsBorders'
      '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
      '<cellXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0" applyProtection="1">'
      '<protection locked="1" hidden="0"/></xf></cellXfs>'
      '</styleSheet>',
      _minimalSheet,
    );

    final patched = patchRawXlsxStyles(encoded, template, allSheets: const ['Sheet1'], alignmentSheets: const ['Sheet1']);
    final styles = _stylesOf(patched);

    final xf = styles.findAllElements('cellXfs').first.findElements('xf').last;
    final childNames = xf.children.whereType<XmlElement>().map((e) => e.name.local).toList();

    expect(childNames, contains('alignment'));
    expect(childNames, contains('protection'));
    expect(childNames.indexOf('alignment'), lessThan(childNames.indexOf('protection')),
        reason: 'CT_Xf requires <alignment> before <protection> -- real Excel rejects the reverse order '
            'as a Load error and repairs the file, discarding styles.xml');
  });

  group('formula cache recomputation (section: formulas blank in Protected View)', () {
    const workbookNoCalcPr = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';

    test('computes and caches a real value for a resolvable formula, discarding any stale cache', () {
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="1"><c r="A1" s="0"><f>1+1</f><v></v></c></row></sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final cell = _sheetOf(patched).findAllElements('c').first;
      final childNames = cell.children.whereType<XmlElement>().map((e) => e.name.local).toList();

      expect(childNames, ['f', 'v'], reason: 'f-then-v matches CT_Cell\'s required child sequence');
      expect(cell.findElements('v').first.innerText, '2.0');
    });

    test('sums real numeric operand cells for a SUM(range) formula', () {
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData>'
          '<row r="8"><c r="C8" s="0"><v>200</v></c></row>'
          '<row r="9"><c r="C9" s="0"><v>100</v></c></row>'
          '<row r="28"><c r="C28" s="0"><f>SUM(C8:C27)</f></c></row>'
          '</sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final c28 = _sheetOf(patched)
          .findAllElements('c')
          .firstWhere((c) => c.getAttribute('r') == 'C28');

      expect(c28.findElements('v').first.innerText, '300.0',
          reason: 'blank rows within the range (C10:C27, never written) must count as 0, matching real SUM semantics');
    });

    test('a cell present with a style but no <v> at all resolves as 0.0, not as unresolvable', () {
      // The real-world case this guards: style_heal.dart gives every cell
      // in the operand columns a style (`<c r="D8" s="28"/>`, no <v>) even
      // on a freshly-created period with zero receipts entered yet -- that
      // must count as blank/0 in a SUM/addition, not poison the whole
      // formula to "unresolvable" the way a genuinely missing operand
      // (caught by a separate test) correctly does.
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="8">'
          '<c r="C8" s="28"/><c r="D8" s="28"><v>45.99</v></c><c r="E8" s="28"/>'
          '<c r="F8" s="28"/><c r="G8" s="28"/><c r="H8" s="28"/>'
          '<c r="I8" s="29"><f>+H8+G8+F8+E8+D8+C8</f></c>'
          '</row></sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final i8 = _sheetOf(patched).findAllElements('c').firstWhere((c) => c.getAttribute('r') == 'I8');

      expect(i8.findElements('v'), isNotEmpty, reason: 'style-only blank operand cells must not block computation');
      expect(i8.findElements('v').first.innerText, '45.99');
    });

    test('a formula referencing a non-numeric (shared-string) cell is left without a cached value', () {
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="6"><c r="C6" s="0" t="s"><v>0</v></c></row>'
          '<row r="28"><c r="C28" s="0"><f>SUM(C6:C6)</f></c></row></sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final c28 = _sheetOf(patched)
          .findAllElements('c')
          .firstWhere((c) => c.getAttribute('r') == 'C28');

      expect(c28.children.whereType<XmlElement>().map((e) => e.name.local), ['f'],
          reason: 'never guess a text cell\'s numeric value -- graceful skip, same as before this pass existed');
    });

    test('leaves a non-formula cell untouched', () {
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="1"><c r="A1" s="0"><v>42</v></c></row></sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final cell = _sheetOf(patched).findAllElements('c').first;

      expect(cell.children.whereType<XmlElement>().map((e) => e.name.local), ['v']);
    });

    test('sets fullCalcOnLoad="1" on an existing <calcPr> that lacks it', () {
      const workbook = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
          'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
          '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets>'
          '<calcPr calcId="1" refMode="A1"/></workbook>';
      final bytes = _buildXlsxWithWorkbook(workbook, _minimalSheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final calcPr = _workbookOf(patched).findAllElements('calcPr').single;

      expect(calcPr.getAttribute('fullCalcOnLoad'), '1');
      expect(calcPr.getAttribute('calcId'), '1', reason: 'other existing calcPr attributes must be preserved');
    });

    test('creates <calcPr fullCalcOnLoad="1"> when the workbook has none at all', () {
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, _minimalSheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final calcPr = _workbookOf(patched).findAllElements('calcPr').single;

      expect(calcPr.getAttribute('fullCalcOnLoad'), '1');
    });
  });

  group('missing merged-cell cells (section: J/M columns never bordered)', () {
    const workbookNoCalcPr = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';

    const templateStylesWithBorderedXf = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<styleSheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
        '<fonts count="1"><font/></fonts>'
        '<fills count="1"><fill/></fills>'
        '<borders count="2"><border/><border><left style="thin"><color indexed="64"/></left>'
        '<right style="thin"><color indexed="64"/></right><top style="thin"><color indexed="64"/></top>'
        '<bottom style="thin"><color indexed="64"/></bottom></border></borders>'
        '<cellStyleXfs count="1"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/></cellStyleXfs>'
        '<cellXfs count="2"><xf numFmtId="0" fontId="0" fillId="0" borderId="0"/>'
        '<xf numFmtId="0" fontId="0" fillId="0" borderId="1" applyBorder="1"/></cellXfs>'
        '</styleSheet>';

    test('a missing cell in an existing row is created and then styled by _patchCellStyles', () {
      // Template: I5:J5 merged, both cells carry the bordered style (index 1).
      const templateSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="5"><c r="I5" s="1"/><c r="J5" s="1"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I5:J5"/></mergeCells></worksheet>';
      // Encoded output: J5 was dropped entirely by the excel package -- only
      // the anchor I5 survives.
      const encodedSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="5"><c r="I5" s="1"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I5:J5"/></mergeCells></worksheet>';

      final templateBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, templateSheet, templateStylesWithBorderedXf);
      final encodedBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, encodedSheet, templateStylesWithBorderedXf);

      final patched = patchRawXlsxStyles(encodedBytes, templateBytes, allSheets: const ['Sheet1'], alignmentSheets: const ['Sheet1']);
      final sheet = _sheetOf(patched);
      final cells = sheet.findAllElements('c').toList();

      expect(cells.map((c) => c.getAttribute('r')), containsAll(['I5', 'J5']));
      final j5 = cells.firstWhere((c) => c.getAttribute('r') == 'J5');
      final styles = _stylesOf(patched);
      final cellXfs = styles.findAllElements('cellXfs').first.findElements('xf').toList();
      final j5StyleIndex = int.parse(j5.getAttribute('s') ?? '0');
      expect(cellXfs[j5StyleIndex].getAttribute('borderId'), '1',
          reason: 'the re-inserted J5 placeholder must be picked up and styled by _patchCellStyles, '
              'not just exist as a bare unstyled cell');
    });

    test('creates the whole row when it is entirely missing', () {
      const templateSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="4"><c r="A4" s="0"/></row>'
          '<row r="5"><c r="I5" s="1"/><c r="J5" s="1"/></row>'
          '<row r="6"><c r="A6" s="0"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I5:J5"/></mergeCells></worksheet>';
      const encodedSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="4"><c r="A4" s="0"/></row>'
          '<row r="6"><c r="A6" s="0"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I5:J5"/></mergeCells></worksheet>';

      final templateBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, templateSheet, templateStylesWithBorderedXf);
      final encodedBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, encodedSheet, templateStylesWithBorderedXf);

      final patched = patchRawXlsxStyles(encodedBytes, templateBytes, allSheets: const ['Sheet1'], alignmentSheets: const ['Sheet1']);
      final sheet = _sheetOf(patched);
      final rows = sheet.findAllElements('row').toList();
      final rowRefs = rows.map((r) => r.getAttribute('r')).toList();

      expect(rowRefs, ['4', '5', '6'], reason: 'the missing row must be re-created in correct sorted position');
      final row5 = rows.firstWhere((r) => r.getAttribute('r') == '5');
      expect(row5.findElements('c').map((c) => c.getAttribute('r')), ['I5', 'J5']);
    });

    test('inserts a missing cell at the correct sorted column position among existing cells', () {
      const templateSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="8"><c r="H8" s="0"/><c r="I8" s="1"/><c r="J8" s="1"/><c r="K8" s="0"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I8:J8"/></mergeCells></worksheet>';
      const encodedSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="8"><c r="H8" s="0"/><c r="I8" s="1"/><c r="K8" s="0"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I8:J8"/></mergeCells></worksheet>';

      final templateBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, templateSheet, templateStylesWithBorderedXf);
      final encodedBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, encodedSheet, templateStylesWithBorderedXf);

      final patched = patchRawXlsxStyles(encodedBytes, templateBytes, allSheets: const ['Sheet1'], alignmentSheets: const ['Sheet1']);
      final row = _sheetOf(patched).findAllElements('row').first;

      expect(row.findElements('c').map((c) => c.getAttribute('r')), ['H8', 'I8', 'J8', 'K8'],
          reason: 'OOXML requires strictly ascending column order within a row; real Excel repairs the '
              'file on open otherwise, same class of bug as the <alignment>/<protection> ordering fix');
    });

    test('leaves an already-present cell untouched (no duplicate insertion)', () {
      const templateSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="5"><c r="I5" s="1"/><c r="J5" s="1"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I5:J5"/></mergeCells></worksheet>';
      const encodedSheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="5"><c r="I5" s="1"/><c r="J5" s="0"/></row></sheetData>'
          '<mergeCells count="1"><mergeCell ref="I5:J5"/></mergeCells></worksheet>';

      final templateBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, templateSheet, templateStylesWithBorderedXf);
      final encodedBytes = _buildXlsxWithWorkbookAndStyles(workbookNoCalcPr, encodedSheet, templateStylesWithBorderedXf);

      final patched = patchRawXlsxStyles(encodedBytes, templateBytes, allSheets: const ['Sheet1'], alignmentSheets: const ['Sheet1']);
      final row = _sheetOf(patched).findAllElements('row').first;
      final cellRefs = row.findElements('c').map((c) => c.getAttribute('r')).toList();

      expect(cellRefs, ['I5', 'J5'], reason: 'no duplicate <c r="J5"> should be inserted when one already exists');
    });
  });
}
