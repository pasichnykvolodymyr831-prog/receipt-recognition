// Regression test for Пакет 15 (audit 2026-08-18): the `excel`-package
// (v4.0.6) cell-style/merge-cell-continuation defects raw_style_patch.dart
// repairs are workbook-global -- merely decoding and re-encoding the whole
// workbook (via engine.excel.encode()) can silently drop a hidden sheet's
// merge-continuation cells again, even when nothing on that sheet was
// touched this write. Previously, `alignmentSheets` in
// safe_xlsx_write.dart only included the 5 hidden Mileage Report sheets
// when `healHiddenSheets=true` (period creation only) -- so any later,
// ordinary write (a receipt, a driving detail) left hidden-sheet corruption
// unrepaired and undetected, indefinitely. This test creates a period
// (hidden sheets healed at creation), then does one ordinary follow-up
// write, and confirms every hidden sheet's declared `<mergeCell>` ranges
// still have all their cells present in `<sheetData>` afterward.
import 'dart:convert';
import 'dart:io';

import 'package:archive/archive.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';
import 'package:xml/xml.dart';

import 'package:expenseflow/services/safe_xlsx_write.dart';
import 'package:expenseflow/xlsx/managed_cells.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';

/// Sheet name -> raw sheet XML, resolved via workbook.xml + rels, mirroring
/// raw_style_patch.dart's own (private) `_sheetFileMap` approach.
Map<String, XmlDocument> _sheetXmlByName(List<int> xlsxBytes) {
  final archive = ZipDecoder().decodeBytes(xlsxBytes);
  XmlDocument readXml(String path) => XmlDocument.parse(utf8.decode(archive.findFile(path)!.content as List<int>));

  final workbookDoc = readXml('xl/workbook.xml');
  final relsDoc = readXml('xl/_rels/workbook.xml.rels');
  final ridToTarget = <String, String>{
    for (final rel in relsDoc.findAllElements('Relationship'))
      if (rel.getAttribute('Id') != null && rel.getAttribute('Target') != null)
        rel.getAttribute('Id')!: rel.getAttribute('Target')!,
  };

  final result = <String, XmlDocument>{};
  for (final sheet in workbookDoc.findAllElements('sheet')) {
    final name = sheet.getAttribute('name');
    final rid = sheet.getAttribute('r:id') ??
        sheet.getAttribute('id', namespace: 'http://schemas.openxmlformats.org/officeDocument/2006/relationships');
    if (name == null || rid == null) continue;
    final target = ridToTarget[rid];
    if (target == null) continue;
    final path = 'xl/${target.replaceFirst(RegExp(r'^/?(xl/)?'), '')}';
    result[name] = readXml(path);
  }
  return result;
}

int _colNum(String letters) {
  var n = 0;
  for (final ch in letters.codeUnits) {
    n = n * 26 + (ch - 64);
  }
  return n;
}

/// Every cell inside every declared `<mergeCell>` range must actually exist
/// in `<sheetData>` -- the excel-package defect #6 this guards against
/// (raw_style_patch.dart module doc) silently drops merge-continuation
/// cells that were only ever given a style, never a value.
List<String> _missingMergedCellRefs(XmlDocument sheetDoc) {
  final missing = <String>[];
  final mergeCellsEl = sheetDoc.findAllElements('mergeCells');
  if (mergeCellsEl.isEmpty) return missing;

  final present = <String>{
    for (final c in sheetDoc.findAllElements('c'))
      if (c.getAttribute('r') != null) c.getAttribute('r')!,
  };

  final rangeRe = RegExp(r'^([A-Z]+)(\d+):([A-Z]+)(\d+)$');
  for (final mergeCell in mergeCellsEl.first.findElements('mergeCell')) {
    final ref = mergeCell.getAttribute('ref');
    if (ref == null) continue;
    final m = rangeRe.firstMatch(ref);
    if (m == null) continue;
    final colStart = _colNum(m.group(1)!);
    final rowStart = int.parse(m.group(2)!);
    final colEnd = _colNum(m.group(3)!);
    final rowEnd = int.parse(m.group(4)!);
    for (var r = rowStart; r <= rowEnd; r++) {
      for (var c = colStart; c <= colEnd; c++) {
        final cellRef = '${_colLetters(c)}$r';
        if (!present.contains(cellRef)) missing.add(cellRef);
      }
    }
  }
  return missing;
}

String _colLetters(int col) {
  var n = col;
  var s = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final docsDir = await Directory.systemTemp.createTemp('hidden_sheet_protection_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  test('hidden sheets keep zero missing merged-cell refs after an ordinary (non-creation) write', () async {
    final dir = await Directory.systemTemp.createTemp('hidden_sheet_protection_test');
    final file = File('${dir.path}/MileageReport_test.xlsx');

    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );

    // An ordinary follow-up write -- healHiddenSheets=false internally,
    // exactly the path that used to leave hidden sheets unprotected.
    await saveMileageDrivingDetail(
      file,
      date: DateTime(2026, 8, 10),
      trip: 'Site A to Site B',
      km: 42.5,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );

    final sheetsByName = _sheetXmlByName(await file.readAsBytes());
    for (final hiddenSheet in mileageHiddenSheets) {
      final sheetDoc = sheetsByName[hiddenSheet];
      expect(sheetDoc, isNotNull, reason: 'hidden sheet "$hiddenSheet" missing from written file entirely');
      final missing = _missingMergedCellRefs(sheetDoc!);
      expect(missing, isEmpty,
          reason: 'hidden sheet "$hiddenSheet" lost merge-continuation cells after an ordinary write: $missing');
    }

    await dir.delete(recursive: true);
  });
}
