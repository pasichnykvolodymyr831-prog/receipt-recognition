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
  // Paths already checked (and restored, if needed) in this process's
  // lifetime. restoreIfCorrupted's job (section 13.5) is specifically
  // recovering from a PREVIOUS session's kill-mid-write -- within one
  // continuous run, this app's own writes are already atomic (temp file +
  // rename, see safe_xlsx_write.dart's _atomicWrite) and nothing else
  // touches these files, so a file validated once this session can never
  // become newly corrupted before the next reload checks it again. A fresh
  // process gets a fresh BackupManager (HomeScreen -- MaterialApp.home --
  // owns the one instance restoreIfCorrupted is ever called through, for
  // its own process lifetime), so this cache never survives a real restart,
  // which is the only case the check still needs to run for.
  final Set<String> _validatedThisSession = {};

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
    if (_validatedThisSession.contains(targetFile.path)) return;
    final backup = await backupFileFor(targetFile);
    await restoreIfCorruptedUsing(targetFile, backup);
    _validatedThisSession.add(targetFile.path);
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
  /// Writes via a tmp-file-then-rename, the same atomic-replace pattern
  /// `safe_xlsx_write.dart`'s `_atomicWrite` already uses for the primary
  /// period file -- previously this was the one write in the whole pipeline
  /// that wrote `backupSlot` directly, so a crash mid-write here could leave
  /// a truncated `.bak` (audit 2026-08-18, Пакет 21).
  static Future<void> backupBeforeWriteTo(File targetFile, File backupSlot) async {
    if (!await targetFile.exists()) return;
    final bytes = await targetFile.readAsBytes();
    final tmp = File('${backupSlot.path}.tmp');
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(backupSlot.path);
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
