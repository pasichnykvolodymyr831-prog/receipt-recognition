import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Repairs seven `excel`-package (v4.0.6) defects that its own object model
/// can never detect or fix, by working directly on the encoded xlsx bytes'
/// raw XML -- the same "bypass the package" approach [xlsx_raw_inspect.dart]
/// already uses for sheet-hidden state, applied here to cell style (font,
/// border, fill, alignment, number format), column widths/hidden state, row
/// heights, formula cache values, cells dropped from merged ranges, and
/// number-format-table bloat:
///
/// 1. Alignment: `parse.dart`'s cellXf parser reads the `horizontal`/
///    `vertical` attributes off the `<xf>` node instead of its `<alignment>`
///    child (a real bug in the package, confirmed by source inspection --
///    those attributes only ever exist on `<alignment>`, so the read is
///    always null and every cell decodes to the default Left/Bottom,
///    including when decoding the *template*). Since the app's heal
///    (style_heal.dart) can only ever copy a `CellStyle` obtained by
///    decoding the template through this same broken parser, it is
///    structurally incapable of restoring horizontal/vertical alignment --
///    only a raw-XML read of the template can recover the true values.
///    (`wrapText` is unaffected: that one attribute is correctly read off
///    the `<alignment>` child a few lines above the bug.)
/// 2. Font/border/fill: these normally decode and heal correctly through
///    style_heal.dart -- *except* for a small, fixed set of cells the
///    package's own `_styleChanges` global-flag/index-0-fallback defect
///    (documented in full_style_parity_test.dart) corrupts on `.encode()`
///    even when the in-memory `CellStyle` was verified correct right
///    beforehand. `_patchCellStyles` compares each cell's font/border/fill
///    *definition* (not its index, which isn't comparable across
///    documents) against the template's and repairs any mismatch the same
///    way it repairs alignment -- so this closes that defect's effect too,
///    for any cell, without needing to know in advance which ones it hits.
/// 3. Column widths: `save_file.dart`'s `_setColumns` unconditionally
///    rebuilds `<cols>` from the in-memory `getColumnWidths`/
///    `getColumnAutoFits` maps, permanently materializing a computed
///    auto-fit width for any column the template left unset (bestFit, no
///    explicit width) -- and dropping any `hidden="1"` the template's
///    `<col>` elements carried, since the rebuilt elements never carry it.
/// 4. Row heights: `save_file.dart`'s `_setRows` skips emitting a `<row>`
///    element entirely for any row with zero cells (`_sheetData[row] ==
///    null`), silently losing that row's explicit height if it was a blank
///    spacer row with no cell content.
/// 5. Formula cache values: the package never evaluates formulas, and
///    round-trips "no computed value" as a *present but empty* `<v></v>`
///    (confirmed present even in the pristine, never-touched template)
///    rather than a real number or an absent `<v>` -- observed to make a
///    real user's Excel never recalculate the formula on open (manual F9
///    required) despite `<calcPr fullCalcOnLoad="1">` already being set.
///    `_stripFormulaValueCache` removes the cached value outright so an
///    absent `<v>` unambiguously tells Excel "no cache, please compute";
///    `_ensureFullCalcOnLoad` guarantees the workbook-level trigger for
///    that computation is always set, not just observed to survive today.
/// 6. Merged-cell cells vanish entirely: a cell that's part of a merged
///    range but was only ever given a style (never a *value* -- e.g. the
///    "J" half of an `I:J` merge, the app only ever writes into the anchor
///    `I`) is silently dropped from `<sheetData>` on `.encode()`, the
///    cell-level twin of defect #4's row-dropping. No Load error results
///    (Excel tolerates a `<mergeCell>` referencing an absent cell), but
///    Excel then has nothing to render a border/fill from for that cell --
///    confirmed on a real device file (J and M columns completely
///    blank/unbordered in real Excel on every data row, despite the merge
///    and the anchor cell's own style both being intact).
///    `_insertMissingMergedCells` re-inserts a bare placeholder for any
///    such missing cell, then leaves it for `_patchCellStyles` (which runs
///    immediately after, in the same per-sheet loop) to heal its style
///    exactly like any other cell.
/// 7. Number-format table bloat: on every `.encode()`, the package doesn't
///    preserve built-in numFmtIds (0-163) as built-in -- it materializes
///    each one in use as a *new* custom `<numFmt>` entry and repoints every
///    referencing `<xf>` at it. Since nothing marks a materialized entry as
///    having originally been built-in, the next decode/re-encode cycle
///    materializes it *again* into yet another new entry, compounding on
///    every single write (confirmed empirically: +8 `cellXfs` entries
///    referencing a custom numFmtId per write cycle against the real
///    bundled template). A `styles.xml` left in that state risks Excel's
///    strict loader rejecting the part outright and silently
///    repairing-and-reformatting the workbook on open.
///    `_canonicalizeBuiltinNumFmts` collapses any custom numFmt that's
///    equivalent to a built-in code back onto the built-in id, breaking the
///    compounding cycle; `_patchCellStyles` additionally compares each
///    cell's resolved number-format *code* (not index) against the
///    template's and repairs any mismatch, same as font/border/fill.
///
/// Column-width/hidden, row-height, and formula-cache repairs are applied
/// for every sheet named in [allSheets] (these are workbook-encode-time
/// defects, not per-cell corruption, so they recur on every single save
/// regardless of which sheets style_heal.dart actually touches). Cell-style
/// repair (including re-inserting missing merged cells, which only matters
/// immediately before it) is scoped to [alignmentSheets] -- normally the
/// same sheets style_heal.dart heals on this write, since properties 1-2
/// above share the same root cause (a cell's `<xf>` no longer being the
/// template's original entry).
/// ECMA-376 (§18.8.30) built-in number format codes -- ids below 164 are
/// implied by the standard and never listed explicitly in a workbook's own
/// `<numFmts>`; ids 164+ are always document-local custom entries.
const _builtinNumFmts = <int, String>{
  0: 'General',
  1: '0',
  2: '0.00',
  3: '#,##0',
  4: '#,##0.00',
  9: '0%',
  10: '0.00%',
  11: '0.00E+00',
  12: '# ?/?',
  13: '# ??/??',
  14: 'mm-dd-yy',
  15: 'd-mmm-yy',
  16: 'd-mmm',
  17: 'mmm-yy',
  18: 'h:mm AM/PM',
  19: 'h:mm:ss AM/PM',
  20: 'h:mm',
  21: 'h:mm:ss',
  22: 'm/d/yy h:mm',
  37: '#,##0 ;(#,##0)',
  38: '#,##0 ;[Red](#,##0)',
  39: '#,##0.00;(#,##0.00)',
  40: '#,##0.00;[Red](#,##0.00)',
  45: 'mm:ss',
  46: '[h]:mm:ss',
  47: 'mmss.0',
  48: '##0.0E+0',
  49: '@',
};

/// Custom numFmtId -> formatCode entries declared in a styles.xml's
/// `<numFmts>` block, keyed by id (sparse, unlike fonts/fills/borders which
/// are dense 0-based lists) since ids are the only stable cross-document
/// reference for a custom format.
Map<int, String> _numFmtsOf(XmlDocument stylesDoc) {
  final result = <int, String>{};
  final numFmtsElements = stylesDoc.findAllElements('numFmts');
  if (numFmtsElements.isEmpty) return result;
  for (final numFmt in numFmtsElements.first.findElements('numFmt')) {
    final id = int.tryParse(numFmt.getAttribute('numFmtId') ?? '');
    final code = numFmt.getAttribute('formatCode');
    if (id != null && code != null) result[id] = code;
  }
  return result;
}

/// The format code an `<xf>`'s numFmtId resolves to within its own
/// document, or null if it references neither a built-in id nor a listed
/// custom one (shouldn't happen for a well-formed workbook, but a missing
/// mapping should never crash the patch).
String? _numFmtCodeOf(XmlElement xf, Map<int, String> customNumFmts) {
  final id = int.tryParse(xf.getAttribute('numFmtId') ?? '0') ?? 0;
  return _builtinNumFmts[id] ?? customNumFmts[id];
}

/// Finds an id in the output document whose format code is [desiredCode]
/// (built-in first, then already-declared custom entries), or mints a new
/// custom `<numFmt>` entry (next id past the highest currently in use) if
/// none exists -- creating the `<numFmts>` element itself, inserted before
/// `<fonts>` per the CT_Stylesheet schema's child order, if the output
/// document doesn't have one yet. [outputNumFmts] is updated in place so
/// later cells needing the same code reuse this entry instead of
/// duplicating it.
int _ensureNumFmtId(XmlDocument outputStylesDoc, Map<int, String> outputNumFmts, String desiredCode) {
  for (final entry in _builtinNumFmts.entries) {
    if (entry.value == desiredCode) return entry.key;
  }
  for (final entry in outputNumFmts.entries) {
    if (entry.value == desiredCode) return entry.key;
  }

  final existing = outputStylesDoc.findAllElements('numFmts');
  XmlElement numFmtsElement;
  if (existing.isEmpty) {
    numFmtsElement = XmlElement(XmlName('numFmts'), [XmlAttribute(XmlName('count'), '0')], []);
    final fontsElement = outputStylesDoc.findAllElements('fonts').first;
    fontsElement.parent!.children.insert(fontsElement.parent!.children.indexOf(fontsElement), numFmtsElement);
  } else {
    numFmtsElement = existing.first;
  }

  final newId = <int>[163, ...outputNumFmts.keys].reduce((a, b) => a > b ? a : b) + 1;
  numFmtsElement.children.add(XmlElement(XmlName('numFmt'), [
    XmlAttribute(XmlName('numFmtId'), '$newId'),
    XmlAttribute(XmlName('formatCode'), desiredCode),
  ], []));
  outputNumFmts[newId] = desiredCode;
  return newId;
}

/// Strips xlsx format-code escape backslashes (e.g. `d\-mmm\-yy` -> `d-mmm-yy`)
/// so a custom numFmt's code can be compared against the (unescaped)
/// built-in table for equivalence, not byte-identity.
String _unescapeNumFmtCode(String code) => code.replaceAll(r'\', '');

/// Fixes the root cause of the numFmts/cellXfs bloat documented in the
/// module doc (defect #7): every time the `excel` package re-encodes a
/// workbook, it doesn't preserve built-in numFmtIds (0-163) as built-in --
/// it "materializes" each one actually in use as a *new* custom `<numFmt>`
/// entry (164+) with an equivalent formatCode, and repoints every `<xf>`
/// that used the built-in id at the new custom one. Decoding and
/// re-encoding again materializes *those* into yet another new set, since
/// nothing marks them as having originally been built-in -- compounding
/// every single write.
///
/// This collapses any custom `<numFmt>` whose formatCode exactly matches
/// (modulo escape backslashes) a built-in code back onto the built-in id,
/// repoints every `<xf>` in `<cellXfs>` and `<cellStyleXfs>` that
/// referenced the custom id, and removes the now-unreferenced `<numFmt>`
/// entries. Deliberately only ever rewrites a `numFmtId` *attribute value*
/// on existing `<xf>` elements -- it never changes the count, position, or
/// identity of any `cellXfs`/`cellStyleXfs` entry, so every existing
/// `<c s="N">`/`xfId="N"`/`<cols style="N">` reference stays exactly as
/// valid (or invalid) as it already was. Must run before [patchRawXlsxStyles]
/// captures its `outputXfs`/`outputNumFmts` snapshots, so the rest of that
/// function sees the already-canonicalized table.
void _canonicalizeBuiltinNumFmts(XmlDocument stylesDoc) {
  final numFmtsElements = stylesDoc.findAllElements('numFmts');
  if (numFmtsElements.isEmpty) return;
  final numFmtsElement = numFmtsElements.first;

  final toBuiltin = <int, int>{};
  final toRemove = <XmlElement>[];
  for (final numFmt in numFmtsElement.findElements('numFmt')) {
    final id = int.tryParse(numFmt.getAttribute('numFmtId') ?? '');
    final code = numFmt.getAttribute('formatCode');
    if (id == null || code == null) continue;
    final normalized = _unescapeNumFmtCode(code);
    for (final builtin in _builtinNumFmts.entries) {
      if (builtin.value == normalized) {
        toBuiltin[id] = builtin.key;
        toRemove.add(numFmt);
        break;
      }
    }
  }
  if (toBuiltin.isEmpty) return;

  for (final xf in [
    ...stylesDoc.findAllElements('cellXfs').first.findElements('xf'),
    ...stylesDoc.findAllElements('cellStyleXfs').first.findElements('xf'),
  ]) {
    final id = int.tryParse(xf.getAttribute('numFmtId') ?? '');
    final mapped = id == null ? null : toBuiltin[id];
    if (mapped != null) {
      xf.setAttribute('numFmtId', '$mapped');
    }
  }

  for (final numFmt in toRemove) {
    numFmt.parent?.children.remove(numFmt);
  }
  final remaining = numFmtsElement.findElements('numFmt').length;
  if (remaining == 0) {
    numFmtsElement.parent?.children.remove(numFmtsElement);
  } else {
    numFmtsElement.setAttribute('count', '$remaining');
  }
}

Uint8List patchRawXlsxStyles(
  Uint8List encodedBytes,
  Uint8List templateBytes, {
  required List<String> allSheets,
  required List<String> alignmentSheets,
}) {
  final archive = ZipDecoder().decodeBytes(encodedBytes);
  final templateArchive = ZipDecoder().decodeBytes(templateBytes);

  final sheetFiles = _sheetFileMap(archive);
  final templateSheetFiles = _sheetFileMap(templateArchive);

  final workbookDoc = _readXml(archive, 'xl/workbook.xml');
  _ensureFullCalcOnLoad(workbookDoc);

  final stylesDoc = _readXml(archive, 'xl/styles.xml');
  final templateStylesDoc = _readXml(templateArchive, 'xl/styles.xml');
  _canonicalizeBuiltinNumFmts(stylesDoc);
  final cellXfsElement = stylesDoc.findAllElements('cellXfs').first;
  final outputXfs = cellXfsElement.findElements('xf').toList(growable: false);
  final templateXfs = templateStylesDoc.findAllElements('cellXfs').first.findElements('xf').toList(growable: false);
  final fillsElement = stylesDoc.findAllElements('fills').first;
  final outputFills = fillsElement.findElements('fill').toList(growable: false);
  final templateFills = templateStylesDoc.findAllElements('fills').first.findElements('fill').toList(growable: false);
  final fontsElement = stylesDoc.findAllElements('fonts').first;
  final outputFonts = fontsElement.findElements('font').toList(growable: false);
  final templateFonts = templateStylesDoc.findAllElements('fonts').first.findElements('font').toList(growable: false);
  final bordersElement = stylesDoc.findAllElements('borders').first;
  final outputBorders = bordersElement.findElements('border').toList(growable: false);
  final templateBorders =
      templateStylesDoc.findAllElements('borders').first.findElements('border').toList(growable: false);
  final outputNumFmts = _numFmtsOf(stylesDoc);
  final templateNumFmts = _numFmtsOf(templateStylesDoc);

  final patchedSheetDocs = <String, XmlDocument>{};

  for (final name in allSheets) {
    final sheetFile = sheetFiles[name];
    final templateSheetFile = templateSheetFiles[name];
    if (sheetFile == null || templateSheetFile == null) continue;
    final sheetDoc = _readXml(archive, sheetFile);
    final templateSheetDoc = _readXml(templateArchive, templateSheetFile);

    _patchColumns(sheetDoc, templateSheetDoc);
    _patchRowHeights(sheetDoc, templateSheetDoc);
    _stripFormulaValueCache(sheetDoc);
    if (alignmentSheets.contains(name)) {
      _insertMissingMergedCells(sheetDoc);
      _patchCellStyles(
        outputSheetDoc: sheetDoc,
        outputXfs: outputXfs,
        outputFills: outputFills,
        outputFonts: outputFonts,
        outputBorders: outputBorders,
        cellXfsElement: cellXfsElement,
        fillsElement: fillsElement,
        fontsElement: fontsElement,
        bordersElement: bordersElement,
        templateSheetDoc: templateSheetDoc,
        templateXfs: templateXfs,
        templateFills: templateFills,
        templateFonts: templateFonts,
        templateBorders: templateBorders,
        outputStylesDoc: stylesDoc,
        outputNumFmts: outputNumFmts,
        templateNumFmts: templateNumFmts,
      );
    }

    patchedSheetDocs[sheetFile] = sheetDoc;
  }

  cellXfsElement.setAttribute('count', '${cellXfsElement.findElements('xf').length}');
  fillsElement.setAttribute('count', '${fillsElement.findElements('fill').length}');
  fontsElement.setAttribute('count', '${fontsElement.findElements('font').length}');
  bordersElement.setAttribute('count', '${bordersElement.findElements('border').length}');
  final numFmtsElements = stylesDoc.findAllElements('numFmts');
  if (numFmtsElements.isNotEmpty) {
    numFmtsElements.first.setAttribute('count', '${numFmtsElements.first.findElements('numFmt').length}');
  }

  final newArchive = Archive();
  for (final file in archive.files) {
    if (file.name == 'xl/styles.xml') {
      final content = utf8.encode(stylesDoc.toXmlString());
      newArchive.addFile(ArchiveFile(file.name, content.length, content));
    } else if (file.name == 'xl/workbook.xml') {
      final content = utf8.encode(workbookDoc.toXmlString());
      newArchive.addFile(ArchiveFile(file.name, content.length, content));
    } else if (patchedSheetDocs.containsKey(file.name)) {
      final content = utf8.encode(patchedSheetDocs[file.name]!.toXmlString());
      newArchive.addFile(ArchiveFile(file.name, content.length, content));
    } else {
      newArchive.addFile(file);
    }
  }
  final bytes = ZipEncoder().encode(newArchive);
  if (bytes == null) {
    throw StateError('ZipEncoder().encode() returned null while patching raw styles');
  }
  return Uint8List.fromList(bytes);
}

XmlDocument _readXml(Archive archive, String path) {
  final file = archive.findFile(path);
  if (file == null) {
    throw StateError('$path not found in archive');
  }
  return XmlDocument.parse(utf8.decode(file.content as List<int>));
}

/// Sheet name -> `xl/worksheets/sheetN.xml`, resolved via workbook.xml's
/// `<sheet name=".." r:id="..">` and workbook.xml.rels' `Id -> Target`,
/// exactly like [xlsx_raw_inspect.dart]'s approach for sheet visibility.
Map<String, String> _sheetFileMap(Archive archive) {
  final workbookDoc = _readXml(archive, 'xl/workbook.xml');
  final relsDoc = _readXml(archive, 'xl/_rels/workbook.xml.rels');

  final ridToTarget = <String, String>{};
  for (final rel in relsDoc.findAllElements('Relationship')) {
    final id = rel.getAttribute('Id');
    final target = rel.getAttribute('Target');
    if (id != null && target != null) ridToTarget[id] = target;
  }

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

class _Align {
  final String? horizontal;
  final String? vertical;
  final bool wrap;
  const _Align({this.horizontal, this.vertical, this.wrap = false});

  @override
  bool operator ==(Object other) =>
      other is _Align && other.horizontal == horizontal && other.vertical == vertical && other.wrap == wrap;
  @override
  int get hashCode => Object.hash(horizontal, vertical, wrap);
}

_Align _alignmentOf(XmlElement xf) {
  final aligns = xf.findElements('alignment');
  if (aligns.isEmpty) return const _Align();
  final align = aligns.first;
  final wrapText = align.getAttribute('wrapText');
  return _Align(
    horizontal: align.getAttribute('horizontal'),
    vertical: align.getAttribute('vertical'),
    wrap: wrapText == '1' || wrapText == 'true',
  );
}

/// Map of cell address ("A6") -> its cellXf index, read directly off the
/// sheet's `<c r=".." s="..">` elements (defaults to style index 0, the
/// workbook default, when `s` is absent -- same convention the OOXML spec
/// and the `excel` package itself use).
Map<String, int> _cellStyleIndices(XmlDocument sheetDoc) {
  final result = <String, int>{};
  for (final c in sheetDoc.findAllElements('c')) {
    final ref = c.getAttribute('r');
    if (ref == null) continue;
    final s = c.getAttribute('s');
    result[ref] = s == null ? 0 : int.parse(s);
  }
  return result;
}

/// Finds [desired] among [currentList] (the container's pre-patch entries)
/// by exact serialized match, or clones it into [container] if no
/// equivalent exists yet -- used for `<fill>`/`<font>`/`<border>` alike,
/// since all three are file-local indices that can't be reused as-is
/// against another document's list.
int _ensureRegistryEntry(
  XmlElement container,
  String childName,
  List<XmlElement> currentList,
  XmlElement desired,
  Map<String, int> cache,
) {
  final signature = desired.toXmlString();
  final cached = cache[signature];
  if (cached != null) return cached;

  for (var i = 0; i < currentList.length; i++) {
    if (currentList[i].toXmlString() == signature) {
      cache[signature] = i;
      return i;
    }
  }

  container.children.add(desired.copy());
  final newIndex = container.findElements(childName).length - 1;
  cache[signature] = newIndex;
  return newIndex;
}

/// The definition an `<xf>`'s `fontId`/`borderId`/`fillId` points to, or
/// null if the id is out of range.
XmlElement? _definitionAt(List<XmlElement> definitions, String? idAttr) {
  final id = int.tryParse(idAttr ?? '') ?? 0;
  return id < definitions.length ? definitions[id] : null;
}

/// Fixes, per cell, everything a cell's `<xf>` can carry that the `excel`
/// package (v4.0.6) can silently corrupt on re-encode and that
/// style_heal.dart's `CellStyle`-level healing can never detect or repair:
///
/// - alignment (`horizontal`/`vertical`) -- the package's parser never
///   reads these at all (see module doc), so this is unconditional whenever
///   the template specifies either.
/// - fill/font/border/number_format -- these normally decode and heal
///   correctly, *except* for the small, fixed set of cells the package's
///   own `_styleChanges` global-flag/index-0-fallback defect corrupts on
///   encode (documented in full_style_parity_test.dart) -- compared here by
///   the definition's actual content (not by index, which isn't comparable
///   across documents), so this repairs that defect's effect too, for any
///   cell, without needing to know in advance which ones it hits.
///
/// Every fix (if any) for a cell is folded into a single cloned `<xf>` --
/// cloning from the cell's *current* entry preserves whichever of these
/// five properties didn't need fixing, and the clone is cached per unique
/// combination of current entry + fixes so cells needing the identical
/// repair (e.g. a whole header row) share one new index instead of each
/// minting their own.
void _patchCellStyles({
  required XmlDocument outputSheetDoc,
  required List<XmlElement> outputXfs,
  required List<XmlElement> outputFills,
  required List<XmlElement> outputFonts,
  required List<XmlElement> outputBorders,
  required XmlElement cellXfsElement,
  required XmlElement fillsElement,
  required XmlElement fontsElement,
  required XmlElement bordersElement,
  required XmlDocument templateSheetDoc,
  required List<XmlElement> templateXfs,
  required List<XmlElement> templateFills,
  required List<XmlElement> templateFonts,
  required List<XmlElement> templateBorders,
  required XmlDocument outputStylesDoc,
  required Map<int, String> outputNumFmts,
  required Map<int, String> templateNumFmts,
}) {
  final templateCellStyles = _cellStyleIndices(templateSheetDoc);
  final xfCache = <String, int>{};
  final fillCache = <String, int>{};
  final fontCache = <String, int>{};
  final borderCache = <String, int>{};

  for (final c in outputSheetDoc.findAllElements('c')) {
    final ref = c.getAttribute('r');
    if (ref == null) continue;
    final templateIdx = templateCellStyles[ref];
    if (templateIdx == null || templateIdx >= templateXfs.length) continue;
    final templateXf = templateXfs[templateIdx];

    final currentIdxAttr = c.getAttribute('s');
    final currentIdx = currentIdxAttr == null ? 0 : int.parse(currentIdxAttr);
    if (currentIdx >= outputXfs.length) continue;
    final currentXf = outputXfs[currentIdx];

    // Alignment: wrapText already round-trips correctly through the excel
    // package; only horizontal/vertical need the raw-XML fix.
    final desiredAlign = _alignmentOf(templateXf);
    final needsAlign =
        (desiredAlign.horizontal != null || desiredAlign.vertical != null) && _alignmentOf(currentXf) != desiredAlign;

    final desiredFill = _definitionAt(templateFills, templateXf.getAttribute('fillId'));
    final currentFill = _definitionAt(outputFills, currentXf.getAttribute('fillId'));
    final needsFill = desiredFill != null && desiredFill.toXmlString() != (currentFill?.toXmlString() ?? '');

    final desiredFont = _definitionAt(templateFonts, templateXf.getAttribute('fontId'));
    final currentFont = _definitionAt(outputFonts, currentXf.getAttribute('fontId'));
    final needsFont = desiredFont != null && desiredFont.toXmlString() != (currentFont?.toXmlString() ?? '');

    final desiredBorder = _definitionAt(templateBorders, templateXf.getAttribute('borderId'));
    final currentBorder = _definitionAt(outputBorders, currentXf.getAttribute('borderId'));
    final needsBorder = desiredBorder != null && desiredBorder.toXmlString() != (currentBorder?.toXmlString() ?? '');

    final desiredNumFmt = _numFmtCodeOf(templateXf, templateNumFmts);
    final currentNumFmt = _numFmtCodeOf(currentXf, outputNumFmts);
    final needsNumFmt = desiredNumFmt != null && desiredNumFmt != currentNumFmt;

    if (!needsAlign && !needsFill && !needsFont && !needsBorder && !needsNumFmt) continue;

    final key = '$currentIdx|'
        '${needsAlign ? '${desiredAlign.horizontal}|${desiredAlign.vertical}|${desiredAlign.wrap}' : 'noalign'}|'
        '${needsFill ? desiredFill.toXmlString() : 'nofill'}|'
        '${needsFont ? desiredFont.toXmlString() : 'nofont'}|'
        '${needsBorder ? desiredBorder.toXmlString() : 'noborder'}|'
        '${needsNumFmt ? desiredNumFmt : 'nonumfmt'}';
    var newIdx = xfCache[key];
    if (newIdx == null) {
      final clone = currentXf.copy();
      if (needsAlign) {
        clone.children.removeWhere((n) => n is XmlElement && n.name.local == 'alignment');
        // CT_Xf's child sequence is strictly ordered (alignment, then
        // protection, then extLst) -- inserting at the end put `<alignment>`
        // after an existing `<protection>` child on any cell whose current
        // xf already had one (common on Timesheet's locked-by-default
        // cells, rare on Mileage's), producing a schema-invalid <xf> that
        // real Excel rejects and repairs on open, even though every lenient
        // parser (including the `excel` package's own reader) tolerated it
        // silently. Confirmed against the real ECMA-376 SpreadsheetML XSD.
        clone.children.insert(0, XmlElement(XmlName('alignment'), [
          if (desiredAlign.horizontal != null) XmlAttribute(XmlName('horizontal'), desiredAlign.horizontal!),
          if (desiredAlign.vertical != null) XmlAttribute(XmlName('vertical'), desiredAlign.vertical!),
          if (desiredAlign.wrap) XmlAttribute(XmlName('wrapText'), '1'),
        ], []));
        clone.setAttribute('applyAlignment', '1');
      }
      if (needsFill) {
        final idx = _ensureRegistryEntry(fillsElement, 'fill', outputFills, desiredFill, fillCache);
        clone.setAttribute('fillId', '$idx');
        clone.setAttribute('applyFill', '1');
      }
      if (needsFont) {
        final idx = _ensureRegistryEntry(fontsElement, 'font', outputFonts, desiredFont, fontCache);
        clone.setAttribute('fontId', '$idx');
        clone.setAttribute('applyFont', '1');
      }
      if (needsBorder) {
        final idx = _ensureRegistryEntry(bordersElement, 'border', outputBorders, desiredBorder, borderCache);
        clone.setAttribute('borderId', '$idx');
        clone.setAttribute('applyBorder', '1');
      }
      if (needsNumFmt) {
        final idx = _ensureNumFmtId(outputStylesDoc, outputNumFmts, desiredNumFmt);
        clone.setAttribute('numFmtId', '$idx');
        clone.setAttribute('applyNumberFormat', '1');
      }
      cellXfsElement.children.add(clone);
      newIdx = cellXfsElement.findElements('xf').length - 1;
      xfCache[key] = newIdx;
    }
    c.setAttribute('s', '$newIdx');
  }
}

/// Replaces the output sheet's `<cols>` wholesale with the template's,
/// rather than trying to reconcile them column-by-column: this is a
/// sheet-level structural block (not per-cell shared style state like
/// cellXfs), so there is no dynamic-index bookkeeping to preserve --
/// copying the template's block verbatim is both simplest and exactly
/// matches what "restore the template's column widths and hidden state"
/// means.
void _patchColumns(XmlDocument outputSheetDoc, XmlDocument templateSheetDoc) {
  final templateColsList = templateSheetDoc.findAllElements('cols').toList();
  final outputColsList = outputSheetDoc.findAllElements('cols').toList();

  if (templateColsList.isEmpty) {
    for (final el in outputColsList) {
      el.parent?.children.remove(el);
    }
    return;
  }

  final clonedChildren = templateColsList.first.children.map((n) => n.copy()).toList();
  if (outputColsList.isNotEmpty) {
    final outputCols = outputColsList.first;
    outputCols.children.clear();
    outputCols.children.addAll(clonedChildren);
  } else {
    final worksheet = outputSheetDoc.rootElement;
    final sheetData = outputSheetDoc.findAllElements('sheetData').first;
    final idx = worksheet.children.indexOf(sheetData);
    worksheet.children.insert(idx, XmlElement(XmlName('cols'), [], clonedChildren));
  }
}

/// Restores any row's explicit height that the template defines (via
/// `ht`+`customHeight="1"`) but the output lost -- either because the row's
/// `<row>` element survived with a different height, or (for a blank
/// spacer row with no cells) because `_setRows` dropped the element
/// entirely. New elements are inserted in row-number order to keep the
/// sheet XML well-formed.
void _patchRowHeights(XmlDocument outputSheetDoc, XmlDocument templateSheetDoc) {
  final templateRows = <int, String>{};
  for (final row in templateSheetDoc.findAllElements('row')) {
    final ht = row.getAttribute('ht');
    final customHeight = row.getAttribute('customHeight');
    if (ht == null || (customHeight != '1' && customHeight != 'true')) continue;
    final r = int.tryParse(row.getAttribute('r') ?? '');
    if (r == null) continue;
    templateRows[r] = ht;
  }
  if (templateRows.isEmpty) return;

  final sheetData = outputSheetDoc.findAllElements('sheetData').first;
  final outputRows = <int, XmlElement>{};
  for (final row in sheetData.findElements('row')) {
    final r = int.tryParse(row.getAttribute('r') ?? '');
    if (r != null) outputRows[r] = row;
  }

  for (final entry in templateRows.entries) {
    final r = entry.key;
    final desiredHt = entry.value;
    final existing = outputRows[r];
    if (existing != null) {
      if (existing.getAttribute('ht') != desiredHt || existing.getAttribute('customHeight') == null) {
        existing.setAttribute('ht', desiredHt);
        existing.setAttribute('customHeight', '1');
      }
      continue;
    }

    XmlElement? insertBefore;
    for (final row in sheetData.findElements('row')) {
      final rr = int.tryParse(row.getAttribute('r') ?? '');
      if (rr != null && rr > r) {
        insertBefore = row;
        break;
      }
    }
    final newRow = XmlElement(XmlName('row'), [
      XmlAttribute(XmlName('r'), '$r'),
      XmlAttribute(XmlName('ht'), desiredHt),
      XmlAttribute(XmlName('customHeight'), '1'),
    ], []);
    if (insertBefore != null) {
      sheetData.children.insert(sheetData.children.indexOf(insertBefore), newRow);
    } else {
      sheetData.children.add(newRow);
    }
  }
}

/// Removes the cached `<v>` value from every formula cell (`<c>` with an
/// `<f>` child) unconditionally. The `excel` package (v4.0.6) never
/// evaluates formulas -- it round-trips "no computed value" as a *present
/// but empty* `<v></v>` rather than a real number or an absent `<v>`,
/// confirmed present even in the pristine, never-touched template. A
/// present-but-empty `<v>` risks Excel reading it as "the cached value IS
/// the empty string" rather than the unambiguous "no cache, please
/// compute" an absent `<v>` signals -- exactly what a real user's Excel
/// was observed doing: formulas never recalculated, requiring a manual F9,
/// despite `<calcPr fullCalcOnLoad="1">` (see [_ensureFullCalcOnLoad])
/// already being set. Removing `<v>` outright (not just when empty) is
/// both simpler and more correct: the app never computes real values
/// itself, so any cached value it round-trips through is unreliable by
/// construction, whether empty or not.
void _stripFormulaValueCache(XmlDocument sheetDoc) {
  for (final c in sheetDoc.findAllElements('c')) {
    if (c.findElements('f').isEmpty) continue;
    c.children.removeWhere((n) => n is XmlElement && n.name.local == 'v');
  }
}

/// Ensures `xl/workbook.xml`'s `<calcPr>` has `fullCalcOnLoad="1"` --
/// already present and already survives every write today (verified on a
/// real device file), so this isn't fixing an observed regression; it
/// guarantees the property doesn't silently depend on happening to survive
/// a future `excel`-package behavior change, at near-zero cost. Creates
/// `<calcPr>` (inserted as `<workbook>`'s last child, its required
/// position per the CT_Workbook schema) if the document has none at all.
void _ensureFullCalcOnLoad(XmlDocument workbookDoc) {
  final calcPrs = workbookDoc.findAllElements('calcPr');
  if (calcPrs.isNotEmpty) {
    calcPrs.first.setAttribute('fullCalcOnLoad', '1');
    return;
  }
  workbookDoc.rootElement.children.add(
    XmlElement(XmlName('calcPr'), [XmlAttribute(XmlName('fullCalcOnLoad'), '1')], []),
  );
}

int _columnLettersToNum(String letters) {
  var n = 0;
  for (final ch in letters.codeUnits) {
    n = n * 26 + (ch - 64);
  }
  return n;
}

String _numToColumnLetters(int col) {
  var n = col;
  var s = '';
  while (n > 0) {
    final rem = (n - 1) % 26;
    s = String.fromCharCode(65 + rem) + s;
    n = (n - 1) ~/ 26;
  }
  return s;
}

int? _columnOf(String cellRef) {
  final match = RegExp(r'^([A-Z]+)\d+$').firstMatch(cellRef);
  return match == null ? null : _columnLettersToNum(match.group(1)!);
}

class _CellRange {
  final int colStart, rowStart, colEnd, rowEnd;
  const _CellRange(this.colStart, this.rowStart, this.colEnd, this.rowEnd);
}

_CellRange? _parseCellRange(String ref) {
  final match = RegExp(r'^([A-Z]+)(\d+):([A-Z]+)(\d+)$').firstMatch(ref);
  if (match == null) return null;
  return _CellRange(
    _columnLettersToNum(match.group(1)!),
    int.parse(match.group(2)!),
    _columnLettersToNum(match.group(3)!),
    int.parse(match.group(4)!),
  );
}

/// Excel-package defect #6: a cell that's part of a merged range but was
/// never written a *value* -- only ever gets a style, via style_heal.dart's
/// whole-sheet `cell.cellStyle = template.cellStyle` in-memory pass (e.g.
/// the "J" half of an `I:J` merge, "M" half of an `L:M` merge -- the app
/// only ever writes into the anchor, I/L, never J/M) -- is silently
/// dropped from `<sheetData>` entirely on `.encode()`, the cell-level twin
/// of defect #4's row-dropping. This doesn't trigger a Load error (Excel
/// tolerates a `<mergeCell>` whose range includes a cell absent from
/// sheetData), but it does mean Excel has *nothing* to render a style
/// from there -- no border, no fill, nothing -- confirmed on a real device
/// file (J and M columns completely blank/unbordered in real Excel across
/// every data row, despite the merge declaration and the anchor cell's own
/// style both being intact) and reproduced via the same missing-cell
/// pattern on Timesheet's `A1:H1` merge during an earlier investigation.
///
/// Re-inserts a bare `<c r="ref"/>` placeholder (no `s=`, implicitly style
/// index 0 -- the same convention `_patchCellStyles` already uses for a
/// cell with no `s` attribute) for any cell inside a declared
/// `<mergeCell>` range that's missing from `<sheetData>`, in the correct
/// sorted column position within its row (creating the row too, in correct
/// sorted row position, on the rare occasion the whole row is *also*
/// missing -- reusing the same "find the element after this position"
/// pattern [_patchRowHeights] already uses). Deliberately does not resolve
/// or assign the correct style itself -- that's left entirely to
/// [_patchCellStyles], which runs immediately after this in the per-sheet
/// loop and already compares every `<c>` against the template via the
/// exact same content-comparison logic used for every other cell.
void _insertMissingMergedCells(XmlDocument outputSheetDoc) {
  final mergeCellsEl = outputSheetDoc.findAllElements('mergeCells');
  if (mergeCellsEl.isEmpty) return;

  final sheetData = outputSheetDoc.findAllElements('sheetData').first;
  final existingRows = <int, XmlElement>{};
  for (final row in sheetData.findElements('row')) {
    final r = int.tryParse(row.getAttribute('r') ?? '');
    if (r != null) existingRows[r] = row;
  }

  for (final mergeCell in mergeCellsEl.first.findElements('mergeCell')) {
    final ref = mergeCell.getAttribute('ref');
    if (ref == null) continue;
    final range = _parseCellRange(ref);
    if (range == null) continue;

    for (var r = range.rowStart; r <= range.rowEnd; r++) {
      final row = existingRows.putIfAbsent(r, () {
        final newRow = XmlElement(XmlName('row'), [XmlAttribute(XmlName('r'), '$r')], []);
        XmlElement? insertBefore;
        for (final existing in sheetData.findElements('row')) {
          final rr = int.tryParse(existing.getAttribute('r') ?? '');
          if (rr != null && rr > r) {
            insertBefore = existing;
            break;
          }
        }
        if (insertBefore != null) {
          sheetData.children.insert(sheetData.children.indexOf(insertBefore), newRow);
        } else {
          sheetData.children.add(newRow);
        }
        return newRow;
      });

      for (var c = range.colStart; c <= range.colEnd; c++) {
        final cellRef = '${_numToColumnLetters(c)}$r';
        final alreadyExists = row.findElements('c').any((cell) => cell.getAttribute('r') == cellRef);
        if (alreadyExists) continue;

        final newCell = XmlElement(XmlName('c'), [XmlAttribute(XmlName('r'), cellRef)], []);
        XmlElement? insertBefore;
        for (final existing in row.findElements('c')) {
          final cc = _columnOf(existing.getAttribute('r') ?? '');
          if (cc != null && cc > c) {
            insertBefore = existing;
            break;
          }
        }
        if (insertBefore != null) {
          row.children.insert(row.children.indexOf(insertBefore), newCell);
        } else {
          row.children.add(newCell);
        }
      }
    }
  }
}
