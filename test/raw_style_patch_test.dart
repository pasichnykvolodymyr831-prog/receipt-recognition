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

  group('formula cache stripping (section: formulas never showing a computed value)', () {
    const workbookNoCalcPr = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
        '<workbook xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main" '
        'xmlns:r="http://schemas.openxmlformats.org/officeDocument/2006/relationships">'
        '<sheets><sheet name="Sheet1" sheetId="1" r:id="rId1"/></sheets></workbook>';

    test('removes an empty <v> cached value from a formula cell', () {
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="1"><c r="A1" s="0"><f>1+1</f><v></v></c></row></sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final cell = _sheetOf(patched).findAllElements('c').first;
      final childNames = cell.children.whereType<XmlElement>().map((e) => e.name.local).toList();

      expect(childNames, contains('f'));
      expect(childNames, isNot(contains('v')), reason: 'a present-but-empty <v> risks Excel reading it as a real '
          'cached value instead of "no cache, please compute"');
    });

    test('does not add a <v> to a formula cell that has none', () {
      const sheet = '<?xml version="1.0" encoding="UTF-8" standalone="yes"?>'
          '<worksheet xmlns="http://schemas.openxmlformats.org/spreadsheetml/2006/main">'
          '<sheetData><row r="1"><c r="A1" s="0"><f>1+1</f></c></row></sheetData></worksheet>';
      final bytes = _buildXlsxWithWorkbook(workbookNoCalcPr, sheet);

      final patched = patchRawXlsxStyles(bytes, bytes, allSheets: const ['Sheet1'], alignmentSheets: const []);
      final cell = _sheetOf(patched).findAllElements('c').first;

      expect(cell.children.whereType<XmlElement>().map((e) => e.name.local), ['f']);
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
}
