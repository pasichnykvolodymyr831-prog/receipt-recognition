import 'dart:convert';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:xml/xml.dart';

/// Rewrites package-root-relative relationship targets (`Target="/xl/..."`)
/// to part-relative ones (`Target="worksheets/.."`) in every `.rels` file of
/// an xlsx archive.
///
/// Both forms are legal OOXML (ECMA-376 part 2, section on relationship
/// targets: a Target starting with `/` is resolved against the package
/// root; otherwise against the source part's own folder) -- but the `excel`
/// v4.0.6 package's parser only handles the relative form: `_parseTable` in
/// `parse.dart` does `_excel._archive.findFile('xl/$target')`, unconditionally
/// prepending `xl/`. Given an absolute target like `/xl/worksheets/sheet1.xml`
/// that produces the nonexistent path `xl//xl/worksheets/sheet1.xml`, and
/// `Excel.decodeBytes` crashes outright (null-check on the missing archive
/// file) before the app ever gets a chance to read the workbook.
///
/// openpyxl writes worksheet relationship targets in the absolute form,
/// so any template hand-edited and re-saved through it needs this
/// normalization before `Excel.decodeBytes` can open it at all -- this is a
/// prerequisite for every other fixture/template fed to the app, independent
/// of which sheets/cells it contains.
Uint8List normalizeXlsxRelationshipTargets(Uint8List bytes) {
  final archive = ZipDecoder().decodeBytes(bytes);
  final patchedRels = <String, XmlDocument>{};

  for (final file in archive.files) {
    if (!file.name.endsWith('.rels')) continue;
    final doc = XmlDocument.parse(utf8.decode(file.content as List<int>));
    final partDir = _relsSourcePartDir(file.name);
    var changed = false;

    for (final rel in doc.findAllElements('Relationship')) {
      if (rel.getAttribute('TargetMode') == 'External') continue;
      final target = rel.getAttribute('Target');
      if (target == null || !target.startsWith('/')) continue;
      rel.setAttribute('Target', _toPartRelative(target, partDir));
      changed = true;
    }

    if (changed) patchedRels[file.name] = doc;
  }

  if (patchedRels.isEmpty) return bytes;

  final newArchive = Archive();
  for (final file in archive.files) {
    if (patchedRels.containsKey(file.name)) {
      final content = utf8.encode(patchedRels[file.name]!.toXmlString());
      newArchive.addFile(ArchiveFile(file.name, content.length, content));
    } else {
      newArchive.addFile(file);
    }
  }
  final encoded = ZipEncoder().encode(newArchive);
  if (encoded == null) {
    throw StateError('ZipEncoder().encode() returned null while normalizing relationship targets');
  }
  return Uint8List.fromList(encoded);
}

/// `xl/_rels/workbook.xml.rels` describes relationships from `xl/workbook.xml`
/// -- its source part's directory is `xl`. Root-level `_rels/.rels` -> `''`.
String _relsSourcePartDir(String relsPath) {
  final withoutRelsFile = relsPath.substring(0, relsPath.lastIndexOf('/')); // drop "/<name>.rels"
  final dir = withoutRelsFile.substring(0, withoutRelsFile.length - '_rels'.length);
  return dir.endsWith('/') ? dir.substring(0, dir.length - 1) : dir;
}

/// Converts a package-root-relative target ("/xl/worksheets/sheet1.xml")
/// into one relative to [partDir] ("xl"), inserting "../" segments if the
/// target lies outside partDir.
String _toPartRelative(String absoluteTarget, String partDir) {
  final targetSegments = absoluteTarget.substring(1).split('/');
  final dirSegments = partDir.isEmpty ? <String>[] : partDir.split('/');

  var common = 0;
  while (common < dirSegments.length &&
      common < targetSegments.length - 1 &&
      dirSegments[common] == targetSegments[common]) {
    common++;
  }
  final upCount = dirSegments.length - common;
  final relSegments = [
    for (var i = 0; i < upCount; i++) '..',
    ...targetSegments.skip(common),
  ];
  return relSegments.join('/');
}
