import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

import '../utils/number_input.dart';
import 'formula_eval.dart';

/// Repairs six `excel`-package (v4.0.6) defects that its own object model
/// can never detect or fix, by working directly on the encoded xlsx bytes'
/// raw XML -- the same "bypass the package" approach [xlsx_raw_inspect.dart]
/// already uses for sheet-hidden state, applied here to cell style (font,
/// border, fill, alignment), column widths/hidden state, row heights,
/// formula cache values, and cells dropped from merged ranges:
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
///    rather than a real number -- observed to make a real user's Excel
///    never recalculate the formula on open (manual F9 required) despite
///    `<calcPr fullCalcOnLoad="1">` already being set. Stripping the cached
///    value outright fixes that (an absent `<v>` unambiguously tells Excel
///    "no cache, please compute"), but introduced a second, narrower gap:
///    Excel's Protected View (the sandbox any file carrying a Mark-of-the-
///    Web opens into, e.g. anything the phone "Отправить"s over email/
///    cloud) never runs the calculation engine at all while active, so a
///    formula cell with no cached value renders as completely blank there
///    until the user clicks "Enable Editing" -- confirmed by the user on a
///    real device file. `_recomputeFormulaValues` closes that gap by
///    actually evaluating each formula in Dart ([formula_eval.dart] --
///    every real formula in these templates reduces to `SUM(range)`,
///    `SUM(a*b)`, or a chain of `+cell+cell...`) and writing the real
///    result as the cached `<v>`, so a non-recalculating viewer shows a
///    correct value immediately. `fullCalcOnLoad` still forces a full,
///    independent recalculation the moment real Excel *does* run its
///    engine, so a bug in this evaluator can only ever affect a transient
///    read-only preview, never the number the user actually edits against.
///    Evaluation failure (unsupported syntax, a non-numeric operand, a
///    circular reference) is never fatal -- it just leaves that one cell
///    exactly as before, with no cached value at all.
///    `_ensureFullCalcOnLoad` guarantees the workbook-level recalculation
///    trigger is always set, not just observed to survive today.
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
    _recomputeFormulaValues(sheetDoc);
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

/// Recomputes and re-caches every formula cell's `<v>` value. The `excel`
/// package (v4.0.6) never evaluates formulas -- it round-trips "no computed
/// value" as a *present but empty* `<v></v>` rather than a real number,
/// confirmed present even in the pristine, never-touched template. An
/// unconditionally-empty cache made a real user's Excel never recalculate
/// on open (manual F9 required) despite `<calcPr fullCalcOnLoad="1">` (see
/// [_ensureFullCalcOnLoad]) already being set -- fixed by always stripping
/// any existing `<v>` first, below. But an absent cache also means Excel's
/// Protected View (which never runs the calculation engine while active)
/// renders formula cells as blank until "Enable Editing" -- confirmed on a
/// real device file. Actually evaluating the formula here and writing the
/// real result back closes that gap: any non-recalculating viewer now sees
/// a correct value immediately, while `fullCalcOnLoad` still guarantees a
/// full, independent recalculation the moment real Excel *does* run its
/// engine -- so a bug in [evaluateFormula] can only ever affect a
/// transient read-only preview, never the number the user edits against.
///
/// Builds a single `ref -> <c>` map for the sheet, then resolves each
/// formula through a memoized, cycle-guarded closure: an absent cell
/// resolves as `0.0` (blank = 0, standard SUM/addition semantics -- matches
/// how these ranges already tolerate not-yet-filled rows), a cell with a
/// non-numeric `t` (shared string/bool/error) resolves as `null` (never
/// guess at a text cell's numeric value), a cell with its own `<f>`
/// recurses through the same closure (so e.g. every `L{r} = +K{r}+I{r}`
/// correctly depends on `I{r}`'s own freshly-evaluated result), and a
/// plain `<v>` is parsed directly. [evaluateFormula] never throws --
/// failure at any point (unsupported syntax, an unresolvable operand, a
/// circular reference) simply yields `null`, which this function treats
/// as "leave this cell exactly as before, no cached value" -- the exact
/// same safe fallback the pure-strip behavior already had, never worse.
/// Results are rounded with [round2] (`lib/utils/number_input.dart`), the
/// same helper already used everywhere else money/km is written, so a
/// cached formula result never carries a longer float tail than the app's
/// own values do.
void _recomputeFormulaValues(XmlDocument sheetDoc) {
  final cellsByRef = <String, XmlElement>{};
  for (final c in sheetDoc.findAllElements('c')) {
    final ref = c.getAttribute('r');
    if (ref != null) cellsByRef[ref] = c;
  }

  final memo = <String, double?>{};
  final visiting = <String>{};

  double? resolve(String ref) {
    if (memo.containsKey(ref)) return memo[ref];
    final cell = cellsByRef[ref];
    if (cell == null) return 0.0;
    if (visiting.contains(ref)) return null;
    final type = cell.getAttribute('t');
    if (type != null && type != 'n') return null;

    final fElements = cell.findElements('f');
    double? value;
    if (fElements.isNotEmpty) {
      visiting.add(ref);
      try {
        value = evaluateFormula(fElements.first.innerText, resolve);
      } finally {
        visiting.remove(ref);
      }
    } else {
      final vElements = cell.findElements('v');
      // A cell can exist purely because style_heal.dart gave it a style
      // (`<c r="D8" s="28"/>`, no <v> at all) without the app ever writing
      // a value into it -- e.g. every receipt-column cell on a row with no
      // receipt yet. That's a blank cell, not a malformed one: it must
      // resolve as 0.0 exactly like a cell absent from the map entirely,
      // not null (which would incorrectly poison every SUM/addition that
      // includes an as-yet-unfilled row -- the common case on a fresh
      // period, not an edge case).
      value = vElements.isEmpty ? 0.0 : double.tryParse(vElements.first.innerText);
    }
    memo[ref] = value;
    return value;
  }

  for (final entry in cellsByRef.entries) {
    final cell = entry.value;
    if (cell.findElements('f').isEmpty) continue;
    cell.children.removeWhere((n) => n is XmlElement && n.name.local == 'v');

    double? result;
    try {
      result = resolve(entry.key);
    } catch (_) {
      result = null;
    }
    if (result == null || !result.isFinite) continue;
    cell.children.add(XmlElement(XmlName('v'), [], [XmlText('${round2(result)}')]));
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
