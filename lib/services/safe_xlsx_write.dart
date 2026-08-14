import 'dart:async';
import 'dart:io';
import 'dart:isolate';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter/services.dart' show rootBundle;

import '../models/payroll_period.dart';
import '../xlsx/excel_integrity.dart';
import '../xlsx/managed_cells.dart';
import '../xlsx/mileage_report_engine.dart';
import '../xlsx/raw_style_patch.dart';
import '../xlsx/style_heal.dart';
import '../xlsx/template_assets.dart';
import '../xlsx/timesheet_engine.dart';
import '../xlsx/xlsx_rels_compat.dart';
import 'backup_manager.dart';
import 'style_warning_log.dart';

/// Coarse progress phases for a period-file save, reported via the
/// `onPhase` callback on the write functions below so the UI can show
/// what's happening during a save that (per real-device measurement)
/// commonly takes several seconds -- dominated by the `excel` package's
/// own decode/encode cost, not by anything this app's code does.
/// [reading] covers decoding the existing file to build the engine and
/// applying the caller's edit; [writing] is healing + encoding; [verifying]
/// is the post-encode integrity check. All three happen inside a spawned
/// isolate (see the module doc below) -- reported back to the caller's
/// isolate via a port as they happen.
enum SaveXlsxPhase { reading, writing, verifying }

/// Thrown when a write is rejected because it would have broken workbook
/// integrity (hidden sheets, formulas). The file on disk is left untouched.
class XlsxIntegrityException implements Exception {
  final List<String> issues;
  const XlsxIntegrityException(this.issues);
  @override
  String toString() => 'XlsxIntegrityException: ${issues.join("; ")}';
}

// ---------------------------------------------------------------------
// Why an isolate: decode/heal/encode/verify are synchronous, CPU-bound
// `excel`-package calls (measured on a real device: several seconds for a
// single write). Running them on the UI isolate froze the app solid for
// that whole span -- confirmed on-device: the save progress indicator
// never painted a single frame despite its phase state changing via
// setState, because nothing ever yielded back to the event loop between
// the synchronous decode/heal/encode/verify calls for it to draw with.
// `setState` marks a widget dirty; it doesn't paint anything until the
// isolate's event loop reaches a frame callback, which can't happen while
// a synchronous, non-`await`ing call chain is still running.
//
// Fix: everything CPU-bound (decode the existing/template bytes, apply
// the caller's edit, heal, encode, verify) runs inside a freshly spawned
// isolate per write. The boundary is deliberately narrow and made of
// plain data: bytes and value types in (never an `Excel` object -- those
// can't cross an isolate boundary at all), phase enum values streamed
// back as they happen, and the final encoded bytes (or an exception) out.
// Everything that needs a platform channel (asset loading via rootBundle,
// `path_provider`) or `dart:io` `File` access stays on the caller's
// isolate, before/after the spawn.
// ---------------------------------------------------------------------

final _backupManager = BackupManager();

Uint8List? _mileageTemplateBytesCache;
Future<Uint8List> _mileageTemplateBytes() async {
  return _mileageTemplateBytesCache ??= (await rootBundle.load(mileageReportTemplateAsset)).buffer.asUint8List();
}

Uint8List? _timesheetTemplateBytesCache;
Future<Uint8List> _timesheetTemplateBytes() async {
  return _timesheetTemplateBytesCache ??= (await rootBundle.load(timesheetTemplateAsset)).buffer.asUint8List();
}

// ===================== Mileage Report =====================

class _MileageWriteResult {
  final Uint8List bytes;
  final List<String> styleWarnings;
  const _MileageWriteResult(this.bytes, this.styleWarnings);
}

sealed class _MileageOp {
  const _MileageOp();
}

class _CreateMileagePeriod extends _MileageOp {
  final String periodLabel;
  final String employeeName;
  final DateTime periodEnd;
  const _CreateMileagePeriod({required this.periodLabel, required this.employeeName, required this.periodEnd});
}

class _WriteReceiptOp extends _MileageOp {
  final ReceiptInput receipt;
  const _WriteReceiptOp(this.receipt);
}

class _WriteDrivingDetailOp extends _MileageOp {
  final DateTime date;
  final String trip;
  final double km;
  const _WriteDrivingDetailOp({required this.date, required this.trip, required this.km});
}

class _MileageRequest {
  final Uint8List sourceBytes;
  final Uint8List templateBytes;
  final bool healHiddenSheets;
  final _MileageOp op;
  final SendPort replyPort;
  const _MileageRequest({
    required this.sourceBytes,
    required this.templateBytes,
    required this.healHiddenSheets,
    required this.op,
    required this.replyPort,
  });
}

void _mileageIsolateEntry(_MileageRequest req) {
  try {
    final sourceBytes = normalizeXlsxRelationshipTargets(req.sourceBytes);
    final templateBytes = normalizeXlsxRelationshipTargets(req.templateBytes);
    final engine = MileageReportEngine.fromBytes(sourceBytes);
    switch (req.op) {
      case _CreateMileagePeriod o:
        engine.writePeriodHeader(periodLabel: o.periodLabel, employeeName: o.employeeName);
        engine.initializeKilometersRow(periodEnd: o.periodEnd);
      case _WriteReceiptOp o:
        final kmTotal = engine.sumDrivingDetailsKm();
        engine.writeReceipt(o.receipt, currentKmTotal: kmTotal);
      case _WriteDrivingDetailOp o:
        engine.writeDrivingDetail(date: o.date, trip: o.trip, km: o.km);
    }

    req.replyPort.send(SaveXlsxPhase.writing);
    final template = Excel.decodeBytes(templateBytes);
    healMileageReportStyles(engine.excel, template, includeHiddenSheets: req.healHiddenSheets);
    final healedBytes = engine.excel.encode();
    if (healedBytes == null) {
      req.replyPort.send(StateError('excel.encode() returned null while healing cell styles'));
      return;
    }
    final patchedBytes = patchRawXlsxStyles(
      Uint8List.fromList(healedBytes),
      templateBytes,
      allSheets: [...mileageVisibleSheets, ...mileageHiddenSheets],
      alignmentSheets: req.healHiddenSheets
          ? [...mileageVisibleSheets, ...mileageHiddenSheets]
          : mileageVisibleSheets,
    );

    req.replyPort.send(SaveXlsxPhase.verifying);
    final report = checkMileageReportIntegrity(newBytes: patchedBytes, template: template);
    if (!report.ok) {
      req.replyPort.send(XlsxIntegrityException(report.issues));
      return;
    }

    req.replyPort.send(_MileageWriteResult(patchedBytes, report.styleWarnings));
  } catch (e) {
    req.replyPort.send(e);
  }
}

Future<_MileageWriteResult> _runMileageIsolate({
  required Uint8List sourceBytes,
  required Uint8List templateBytes,
  required bool healHiddenSheets,
  required _MileageOp op,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  final port = ReceivePort();
  final errorPort = ReceivePort();
  final completer = Completer<_MileageWriteResult>();

  final portSub = port.listen((message) {
    if (message is SaveXlsxPhase) {
      onPhase?.call(message);
    } else if (message is _MileageWriteResult) {
      if (!completer.isCompleted) completer.complete(message);
    } else if (!completer.isCompleted) {
      completer.completeError(message);
    }
  });
  final errorSub = errorPort.listen((message) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('Mileage write isolate failed: $message'));
    }
  });

  try {
    await Isolate.spawn(
      _mileageIsolateEntry,
      _MileageRequest(
        sourceBytes: sourceBytes,
        templateBytes: templateBytes,
        healHiddenSheets: healHiddenSheets,
        op: op,
        replyPort: port.sendPort,
      ),
      onError: errorPort.sendPort,
    );
    return await completer.future;
  } finally {
    await portSub.cancel();
    await errorSub.cancel();
    port.close();
    errorPort.close();
  }
}

/// Creates a fresh Mileage Report period file (section 5) from the bundled
/// template, healing all 7 sheets (including the 5 hidden ones) once --
/// see [healMileageReportStyles] for why that's a one-time-at-creation
/// cost rather than something every later write repeats.
Future<void> createMileagePeriod(
  File file, {
  required String periodLabel,
  required String employeeName,
  required DateTime periodEnd,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final templateBytes = await _mileageTemplateBytes();
  final result = await _runMileageIsolate(
    sourceBytes: templateBytes,
    templateBytes: templateBytes,
    healHiddenSheets: true,
    op: _CreateMileagePeriod(periodLabel: periodLabel, employeeName: employeeName, periodEnd: periodEnd),
    onPhase: onPhase,
  );
  await logStyleWarnings('createMileagePeriod', file.uri.pathSegments.last, result.styleWarnings);
  await file.writeAsBytes(result.bytes);
}

/// Adds a receipt to [file]'s Mileage Report (section 7/8). Throws
/// [MileageReportStructureException] if the file was hand-edited outside
/// the app, [MileageReportRowsExhaustedException] if there's no room left,
/// or [XlsxIntegrityException] if the healed result fails verification.
Future<void> saveMileageReceipt(
  File file,
  ReceiptInput receipt, {
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final sourceBytes = await file.readAsBytes();
  final templateBytes = await _mileageTemplateBytes();
  await _backupManager.backupBeforeWrite(file);
  final result = await _runMileageIsolate(
    sourceBytes: sourceBytes,
    templateBytes: templateBytes,
    healHiddenSheets: false,
    op: _WriteReceiptOp(receipt),
    onPhase: onPhase,
  );
  await logStyleWarnings('saveMileageReceipt', file.uri.pathSegments.last, result.styleWarnings);
  await file.writeAsBytes(result.bytes);
}

/// Adds a trip to [file]'s Driving Details sheet and recalculates the
/// Kilometers row (section 7/9). Same exceptions as [saveMileageReceipt].
Future<void> saveMileageDrivingDetail(
  File file, {
  required DateTime date,
  required String trip,
  required double km,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final sourceBytes = await file.readAsBytes();
  final templateBytes = await _mileageTemplateBytes();
  await _backupManager.backupBeforeWrite(file);
  final result = await _runMileageIsolate(
    sourceBytes: sourceBytes,
    templateBytes: templateBytes,
    healHiddenSheets: false,
    op: _WriteDrivingDetailOp(date: date, trip: trip, km: km),
    onPhase: onPhase,
  );
  await logStyleWarnings('saveMileageDrivingDetail', file.uri.pathSegments.last, result.styleWarnings);
  await file.writeAsBytes(result.bytes);
}

// ===================== Timesheet =====================

class _TimesheetWriteResult {
  final Uint8List bytes;
  final List<String> styleWarnings;
  const _TimesheetWriteResult(this.bytes, this.styleWarnings);
}

sealed class _TimesheetOp {
  const _TimesheetOp();
}

class _CreateTimesheetPeriod extends _TimesheetOp {
  final String employeeName;
  final String periodLabel;
  final String phone;
  final PayrollPeriod period;
  const _CreateTimesheetPeriod({
    required this.employeeName,
    required this.periodLabel,
    required this.phone,
    required this.period,
  });
}

class _WriteTimesheetDayOp extends _TimesheetOp {
  final int row;
  final TimesheetDayInput input;
  const _WriteTimesheetDayOp(this.row, this.input);
}

class _TimesheetRequest {
  final Uint8List sourceBytes;
  final Uint8List templateBytes;
  final _TimesheetOp op;
  final SendPort replyPort;
  const _TimesheetRequest({
    required this.sourceBytes,
    required this.templateBytes,
    required this.op,
    required this.replyPort,
  });
}

void _timesheetIsolateEntry(_TimesheetRequest req) {
  try {
    final sourceBytes = normalizeXlsxRelationshipTargets(req.sourceBytes);
    final templateBytes = normalizeXlsxRelationshipTargets(req.templateBytes);
    final engine = TimesheetEngine.fromBytes(sourceBytes);
    switch (req.op) {
      case _CreateTimesheetPeriod o:
        engine.writeHeader(employeeName: o.employeeName, periodLabel: o.periodLabel, phone: o.phone);
        engine.autoFillPeriod(o.period);
      case _WriteTimesheetDayOp o:
        engine.writeDay(o.row, o.input);
    }

    req.replyPort.send(SaveXlsxPhase.writing);
    final template = Excel.decodeBytes(templateBytes);
    healTimesheetStyles(engine.excel, template);
    final healedBytes = engine.excel.encode();
    if (healedBytes == null) {
      req.replyPort.send(StateError('excel.encode() returned null while healing cell styles'));
      return;
    }
    final patchedBytes = patchRawXlsxStyles(
      Uint8List.fromList(healedBytes),
      templateBytes,
      allSheets: const ['Sheet1'],
      alignmentSheets: const ['Sheet1'],
    );

    req.replyPort.send(SaveXlsxPhase.verifying);
    final report = checkTimesheetIntegrity(newBytes: patchedBytes, template: template);
    if (!report.ok) {
      req.replyPort.send(XlsxIntegrityException(report.issues));
      return;
    }

    req.replyPort.send(_TimesheetWriteResult(patchedBytes, report.styleWarnings));
  } catch (e) {
    req.replyPort.send(e);
  }
}

Future<_TimesheetWriteResult> _runTimesheetIsolate({
  required Uint8List sourceBytes,
  required Uint8List templateBytes,
  required _TimesheetOp op,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  final port = ReceivePort();
  final errorPort = ReceivePort();
  final completer = Completer<_TimesheetWriteResult>();

  final portSub = port.listen((message) {
    if (message is SaveXlsxPhase) {
      onPhase?.call(message);
    } else if (message is _TimesheetWriteResult) {
      if (!completer.isCompleted) completer.complete(message);
    } else if (!completer.isCompleted) {
      completer.completeError(message);
    }
  });
  final errorSub = errorPort.listen((message) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('Timesheet write isolate failed: $message'));
    }
  });

  try {
    await Isolate.spawn(
      _timesheetIsolateEntry,
      _TimesheetRequest(sourceBytes: sourceBytes, templateBytes: templateBytes, op: op, replyPort: port.sendPort),
      onError: errorPort.sendPort,
    );
    return await completer.future;
  } finally {
    await portSub.cancel();
    await errorSub.cancel();
    port.close();
    errorPort.close();
  }
}

/// Creates a fresh Timesheet period file (section 5) from the bundled
/// template and auto-fills it per [period] (section 10).
Future<void> createTimesheetPeriod(
  File file, {
  required String employeeName,
  required String periodLabel,
  required String phone,
  required PayrollPeriod period,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final templateBytes = await _timesheetTemplateBytes();
  final result = await _runTimesheetIsolate(
    sourceBytes: templateBytes,
    templateBytes: templateBytes,
    op: _CreateTimesheetPeriod(employeeName: employeeName, periodLabel: periodLabel, phone: phone, period: period),
    onPhase: onPhase,
  );
  await logStyleWarnings('createTimesheetPeriod', file.uri.pathSegments.last, result.styleWarnings);
  await file.writeAsBytes(result.bytes);
}

/// Writes one day's edited times to [file]'s Timesheet (section 10) and
/// returns the resulting bytes so the caller can refresh its own read-only
/// summary of the file without a second decode (see [readTimesheetSummary]).
Future<Uint8List> saveTimesheetDay(
  File file, {
  required int row,
  required TimesheetDayInput input,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final sourceBytes = await file.readAsBytes();
  final templateBytes = await _timesheetTemplateBytes();
  await _backupManager.backupBeforeWrite(file);
  final result = await _runTimesheetIsolate(
    sourceBytes: sourceBytes,
    templateBytes: templateBytes,
    op: _WriteTimesheetDayOp(row, input),
    onPhase: onPhase,
  );
  await logStyleWarnings('saveTimesheetDay', file.uri.pathSegments.last, result.styleWarnings);
  await file.writeAsBytes(result.bytes);
  return result.bytes;
}

/// Read-only summary of a Timesheet file's day rows, extracted inside an
/// isolate (same decode cost as a write, ~1-3s on a real device) so
/// opening/refreshing the Timesheet list screen never blocks the UI
/// isolate either. Deliberately plain data -- no `Excel`/`TimesheetEngine`
/// object crosses back, since those can't cross an isolate boundary.
class TimesheetSummary {
  final List<double?> hoursByRow;
  final List<TimesheetDayInput?> daysByRow;
  final double totalHours;
  const TimesheetSummary({required this.hoursByRow, required this.daysByRow, required this.totalHours});
}

class _SummarizeTimesheetRequest {
  final Uint8List sourceBytes;
  final SendPort replyPort;
  const _SummarizeTimesheetRequest(this.sourceBytes, this.replyPort);
}

void _summarizeTimesheetIsolateEntry(_SummarizeTimesheetRequest req) {
  try {
    final engine = TimesheetEngine.fromBytes(normalizeXlsxRelationshipTargets(req.sourceBytes));
    final hoursByRow = <double?>[];
    final daysByRow = <TimesheetDayInput?>[];
    for (var row = TimesheetEngine.firstDayRow; row <= TimesheetEngine.lastDayRow; row++) {
      hoursByRow.add(engine.readHours(row));
      daysByRow.add(engine.readDay(row));
    }
    req.replyPort.send(TimesheetSummary(
      hoursByRow: hoursByRow,
      daysByRow: daysByRow,
      totalHours: engine.readTotalHours(),
    ));
  } catch (e) {
    req.replyPort.send(e);
  }
}

Future<TimesheetSummary> readTimesheetSummary(File file) async {
  final sourceBytes = await file.readAsBytes();
  final port = ReceivePort();
  final errorPort = ReceivePort();
  final completer = Completer<TimesheetSummary>();

  final portSub = port.listen((message) {
    if (message is TimesheetSummary) {
      if (!completer.isCompleted) completer.complete(message);
    } else if (!completer.isCompleted) {
      completer.completeError(message);
    }
  });
  final errorSub = errorPort.listen((message) {
    if (!completer.isCompleted) {
      completer.completeError(StateError('Timesheet summary isolate failed: $message'));
    }
  });

  try {
    await Isolate.spawn(
      _summarizeTimesheetIsolateEntry,
      _SummarizeTimesheetRequest(sourceBytes, port.sendPort),
      onError: errorPort.sendPort,
    );
    return await completer.future;
  } finally {
    await portSub.cancel();
    await errorSub.cancel();
    port.close();
    errorPort.close();
  }
}
