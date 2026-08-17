import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:path_provider/path_provider.dart';

import '../xlsx/xlsx_rels_compat.dart';

/// Backs up period files before every write and restores them if a file is
/// found corrupted (e.g. the app was killed mid-write) at next launch
/// (section 13.5).
///
/// The path-resolution methods depend on `path_provider` (platform-only);
/// the actual backup/restore logic is factored into plain `File`-based
/// methods below so it can be unit-tested without platform channels.
class BackupManager {
  Future<Directory> _backupDir() async {
    final dir = await getApplicationDocumentsDirectory();
    final backups = Directory('${dir.path}/backups');
    if (!await backups.exists()) {
      await backups.create(recursive: true);
    }
    return backups;
  }

  Future<File> backupFileFor(File targetFile) async {
    final dir = await _backupDir();
    final name = targetFile.uri.pathSegments.last;
    return File('${dir.path}/$name.bak');
  }

  /// Copies the current (pre-write) content of [targetFile] into the backup
  /// slot. No-op if the file doesn't exist yet (nothing to protect).
  Future<void> backupBeforeWrite(File targetFile) async {
    final backup = await backupFileFor(targetFile);
    await backupBeforeWriteTo(targetFile, backup);
  }

  /// If [targetFile] is missing or fails to open as a valid xlsx, restores
  /// it from its backup (if one exists). Call at app startup for every
  /// period file before it's read or written.
  Future<void> restoreIfCorrupted(File targetFile) async {
    final backup = await backupFileFor(targetFile);
    await restoreIfCorruptedUsing(targetFile, backup);
  }

  /// Normalizes `.rels` targets before attempting to decode (see
  /// [MileageReportEngine.fromBytes] for why) -- otherwise a template whose
  /// `.rels` still carries the openpyxl absolute-path quirk would be
  /// reported as "corrupted" even though it's perfectly valid once
  /// normalized, which would make [restoreIfCorruptedUsing] wrongly
  /// overwrite a fine file with a stale backup.
  static bool isValidXlsx(List<int> bytes) {
    try {
      Excel.decodeBytes(normalizeXlsxRelationshipTargets(Uint8List.fromList(bytes)));
      return true;
    } catch (_) {
      return false;
    }
  }

  /// Plain-File version of [backupBeforeWrite]'s logic (unit-testable).
  static Future<void> backupBeforeWriteTo(File targetFile, File backupSlot) async {
    if (!await targetFile.exists()) return;
    await backupSlot.writeAsBytes(await targetFile.readAsBytes());
  }

  /// Plain-File version of [restoreIfCorrupted]'s logic (unit-testable).
  static Future<void> restoreIfCorruptedUsing(File targetFile, File backupSlot) async {
    if (!await targetFile.exists()) {
      if (await backupSlot.exists()) {
        await targetFile.writeAsBytes(await backupSlot.readAsBytes());
      }
      return;
    }

    final bytes = await targetFile.readAsBytes();
    if (!isValidXlsx(bytes) && await backupSlot.exists()) {
      await targetFile.writeAsBytes(await backupSlot.readAsBytes());
    }
  }
}
