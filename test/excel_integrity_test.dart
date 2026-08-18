// Regression tests for Пакет 17 (audit 2026-08-18, section 13 п.6/п.8):
// checkMileageReportIntegrity previously only checked "is this cell a
// formula" (never the formula's actual text) and never checked that
// declared merge ranges (I:J, L:M, etc.) still match the template at all --
// both silent-corruption classes ("file opens fine, looks correct, but is
// actually wrong in real Excel") that have repeatedly bitten this project
// and were only ever caught on a real device file. These tests corrupt one
// specific thing in an otherwise-untouched copy of the real template and
// confirm checkMileageReportIntegrity now catches it.
//
// The merge-range tests corrupt the raw `<mergeCells>` XML directly rather
// than going through the `excel` package's own `merge()`/`unMerge()` +
// `.encode()` -- confirmed by a throwaway diagnostic that a `.encode()`
// round trip silently does NOT reflect an in-memory `unMerge()`/`merge()`
// call at all (a real, if narrow, `excel`-package defect in its own right:
// merge-range mutation via the public API doesn't survive re-encode). Raw
// XML manipulation is the same reliable technique the rest of this
// project's xlsx tests already use for exactly this reason.
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:xml/xml.dart';

import 'package:expenseflow/xlsx/excel_integrity.dart';
import 'package:expenseflow/xlsx/xlsx_rels_compat.dart';

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';

Uint8List _templateBytes() =>
    normalizeXlsxRelationshipTargets(Uint8List.fromList(File(mileageTemplatePath).readAsBytesSync()));

Excel _decodeTemplate() => Excel.decodeBytes(_templateBytes());

/// Sheet name -> `xl/worksheets/sheetN.xml` path, resolved via workbook.xml
/// + rels, mirroring raw_style_patch.dart's own (private) `_sheetFileMap`.
Map<String, String> _sheetFileMap(Archive archive) {
  XmlDocument readXml(String path) => XmlDocument.parse(utf8.decode(archive.findFile(path)!.content as List<int>));
  final workbookDoc = readXml('xl/workbook.xml');
  final relsDoc = readXml('xl/_rels/workbook.xml.rels');
  final ridToTarget = <String, String>{
    for (final rel in relsDoc.findAllElements('Relationship'))
      if (rel.getAttribute('Id') != null && rel.getAttribute('Target') != null)
        rel.getAttribute('Id')!: rel.getAttribute('Target')!,
  };
  final result = <String, String>{};
  for (final sheet in workbookDoc.findAllElements('sheet')) {
    final name = sheet.getAttribute('name');
    final rid = sheet.getAttribute('r:id') ??
        sheet.getAttribute('id', namespace: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships');
    if (name == null || rid == null) continue;
    final target = ridToTarget[rid];
    if (target == null) continue;
    result[name] = 'xl/${target.replaceFirst(RegExp(r'^/?(xl/)?'), '')}';
  }
  return result;
}

/// Rewrites one sheet's raw XML inside an xlsx archive, leaving every other
/// part byte-identical.
Uint8List _withSheetXml(Uint8List xlsxBytes, String sheetName, XmlDocument Function(XmlDocument current) mutate) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  final sheetPath = _sheetFileMap(archive)[sheetName]!;
  final current = XmlDocument.parse(utf8.decode(archive.findFile(sheetPath)!.content as List<int>));
  final mutated = mutate(current);

  final newArchive = Archive();
  for (final file in archive.files) {
    if (file.name == sheetPath) {
      final content = utf8.encode(mutated.toXmlString());
      newArchive.addFile(ArchiveFile(file.name, content.length, content));
    } else {
      newArchive.addFile(file);
    }
  }
  return Uint8List.fromList(ZipEncoder().encode(newArchive)!);
}

void main() {
  test('an untouched copy of the template passes both the formula-text and merge-range checks', () {
    final template = _decodeTemplate();
    final report = checkMileageReportIntegrity(newBytes: _templateBytes(), template: template);

    expect(report.ok, true, reason: report.issues.join('; '));
  });

  test('a corrupted formula string at I8 is caught, not just "is a formula"', () {
    final template = _decodeTemplate();
    final corrupted = _decodeTemplate();
    final sheet = corrupted.sheets['Truman Homes']!;
    final cell = sheet.cell(CellIndex.indexByString('I8'));
    final original = cell.value;
    expect(original, isA<FormulaCellValue>(), reason: 'test setup assumption: I8 must already be a formula');
    cell.value = FormulaCellValue('${(original as FormulaCellValue).formula}+999');

    final report = checkMileageReportIntegrity(newBytes: corrupted.encode()!, template: template);

    expect(report.ok, false);
    expect(report.issues.any((i) => i.contains('Formula at I8 changed')), true,
        reason: 'issues were: ${report.issues.join("; ")}');
  });

  test('a lost merge range on Truman Homes is caught', () {
    final template = _decodeTemplate();
    final corrupted = _withSheetXml(_templateBytes(), 'Truman Homes', (doc) {
      final mergeCell = doc
          .findAllElements('mergeCell')
          .firstWhere((e) => e.getAttribute('ref') == 'I8:J8', orElse: () => throw StateError('I8:J8 not found'));
      mergeCell.parent?.children.remove(mergeCell);
      return doc;
    });

    final report = checkMileageReportIntegrity(newBytes: corrupted, template: template);

    expect(report.ok, false);
    expect(report.issues.any((i) => i.contains('lost merge range') && i.contains('I8:J8')), true,
        reason: 'issues were: ${report.issues.join("; ")}');
  });

  test('an extra, unexpected merge range on Truman Homes is caught', () {
    final template = _decodeTemplate();
    final corrupted = _withSheetXml(_templateBytes(), 'Truman Homes', (doc) {
      final mergeCells = doc.findAllElements('mergeCells').first;
      mergeCells.children.add(XmlElement(XmlName('mergeCell'), [XmlAttribute(XmlName('ref'), 'A40:B40')], []));
      mergeCells.setAttribute('count', '${mergeCells.findElements('mergeCell').length}');
      return doc;
    });

    final report = checkMileageReportIntegrity(newBytes: corrupted, template: template);

    expect(report.ok, false);
    expect(report.issues.any((i) => i.contains('unexpected merge range') && i.contains('A40:B40')), true,
        reason: 'issues were: ${report.issues.join("; ")}');
  });
}
