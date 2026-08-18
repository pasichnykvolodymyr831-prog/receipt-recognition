import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Repairs five `excel`-package (v4.0.6) defects that its own object model
/// can never detect or fix, by working directly on the encoded xlsx bytes'
/// raw XML -- the same "bypass the package" approach [xlsx_raw_inspect.dart]
/// already uses for sheet-hidden state, applied here to cell style (font,
/// border, fill, alignment), column widths/hidden state, row heights, and
/// formula cache values:
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
///
/// Column-width/hidden, row-height, and formula-cache repairs are applied
/// for every sheet named in [allSheets] (these are workbook-encode-time
/// defects, not per-cell corruption, so they recur on every single save
/// regardless of which sheets style_heal.dart actually touches). Cell-style
/// repair is scoped to [alignmentSheets] -- normally the same sheets
/// style_heal.dart heals on this write, since properties 1-2 above share
/// the same root cause (a cell's `<xf>` no longer being the template's
/// original entry).
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
      );
    }

    patchedSheetDocs[sheetFile] = sheetDoc;
  }

  cellXfsElement.setAttribute('count', '${cellXfsElement.findElements('xf').length}');
  fillsElement.setAttribute('count', '${fillsElement.findElements('fill').length}');
  fontsElement.setAttribute('count', '${fontsElement.findElements('font').length}');
  bordersElement.setAttribute('count', '${bordersElement.findElements('border').length}');

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
/// - fill/font/border -- these normally decode and heal correctly, *except*
///   for the small, fixed set of cells the package's own `_styleChanges`
///   global-flag/index-0-fallback defect corrupts on encode (documented in
///   full_style_parity_test.dart) -- compared here by the definition's
///   actual content (not by index, which isn't comparable across
///   documents), so this repairs that defect's effect too, for any cell,
///   without needing to know in advance which ones it hits.
///
/// Every fix (if any) for a cell is folded into a single cloned `<xf>` --
/// cloning from the cell's *current* entry preserves whichever of these
/// four properties didn't need fixing, and the clone is cached per unique
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

    if (!needsAlign && !needsFill && !needsFont && !needsBorder) continue;

    final key = '$currentIdx|'
        '${needsAlign ? '${desiredAlign.horizontal}|${desiredAlign.vertical}|${desiredAlign.wrap}' : 'noalign'}|'
        '${needsFill ? desiredFill.toXmlString() : 'nofill'}|'
        '${needsFont ? desiredFont.toXmlString() : 'nofont'}|'
        '${needsBorder ? desiredBorder.toXmlString() : 'noborder'}';
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
