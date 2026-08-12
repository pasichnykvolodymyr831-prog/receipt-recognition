import 'dart:io';

import 'backup_manager.dart';
import '../xlsx/excel_integrity.dart';

/// Thrown when a write is rejected because it would have broken workbook
/// integrity (hidden sheets, formulas). The file on disk is left untouched.
class XlsxIntegrityException implements Exception {
  final List<String> issues;
  const XlsxIntegrityException(this.issues);
  @override
  String toString() => 'XlsxIntegrityException: ${issues.join("; ")}';
}

final _backupManager = BackupManager();

/// Backs up [file]'s current content, then writes [newBytes] only if they
/// pass [checkMileageReportIntegrity] against that pre-write content
/// (section 13.2, 13.5). Confirms the write actually landed before
/// returning.
Future<void> writeMileageReportSafely(File file, List<int> newBytes) async {
  final originalBytes = await file.exists() ? await file.readAsBytes() : newBytes;
  await _backupManager.backupBeforeWrite(file);

  if (await file.exists()) {
    final report = checkMileageReportIntegrity(originalBytes: originalBytes, newBytes: newBytes);
    if (!report.ok) {
      throw XlsxIntegrityException(report.issues);
    }
  }

  await file.writeAsBytes(newBytes);
}

/// Same as [writeMileageReportSafely] but for the Timesheet workbook, which
/// only needs the "does it open" + Item# sanity check (no hidden sheets or
/// receipt-row formulas to protect).
Future<void> writeTimesheetSafely(File file, List<int> newBytes) async {
  await _backupManager.backupBeforeWrite(file);

  final report = checkTimesheetIntegrity(newBytes: newBytes);
  if (!report.ok) {
    throw XlsxIntegrityException(report.issues);
  }

  await file.writeAsBytes(newBytes);
}
