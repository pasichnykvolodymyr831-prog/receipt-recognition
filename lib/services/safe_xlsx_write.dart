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

/// Ceiling on how long a spawned write/read isolate is allowed to run
/// before it's considered hung rather than just slow. Real-device writes
/// are measured at "several seconds" (see the module doc above) even for
/// the heaviest case (period creation, full 7-sheet heal) -- 60s leaves
/// generous headroom above that while still turning a genuine hang (not a
/// crash, which `onError` already catches) into a surfaced error instead
/// of an indefinitely stuck "saving" UI (audit 2026-08-18, Пакет 22).
const _isolateTimeout = Duration(seconds: 60);

/// Replaces [target]'s content with [bytes] atomically (section 13, step 8):
/// write to a sibling temp file first, then rename it over [target]. A
/// rename within the same filesystem either completes wholly or not at all,
/// so a crash/kill mid-write (battery, force-close) always leaves [target]
/// as either the old version or the new one -- never truncated/corrupt.
/// Must NOT be implemented as delete-then-write: that has a window where
/// [target] doesn't exist at all. The `.tmp` suffix deliberately doesn't end
/// in `.xlsx`, so it can never match the period-file search pattern (section
/// 5) and be mistaken for a second candidate file.
Future<void> _atomicWrite(File target, Uint8List bytes) async {
  final tmp = File('${target.path}.tmp');
  try {
    await tmp.writeAsBytes(bytes, flush: true);
    await tmp.rename(target.path);
  } catch (e) {
    // If the write to the temp file itself failed (e.g. disk full) before
    // the rename, don't leave a partial/orphaned `.tmp` sitting next to the
    // real file forever -- purely a storage-cleanliness concern, [target]
    // itself was never at risk either way (audit 2026-08-18, Пакет 22).
    if (await tmp.exists()) {
      try {
        await tmp.delete();
      } catch (_) {
        // Best-effort cleanup only -- the original [e] is what matters.
      }
    }
    rethrow;
  }
}

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
  final double kmRate;
  const _CreateMileagePeriod({
    required this.periodLabel,
    required this.employeeName,
    required this.periodEnd,
    required this.kmRate,
  });
}

class _WriteReceiptOp extends _MileageOp {
  final ReceiptInput receipt;
  final double? periodKmRate;
  final double settingsDefaultRate;
  const _WriteReceiptOp(this.receipt, {required this.periodKmRate, required this.settingsDefaultRate});
}

class _WriteDrivingDetailOp extends _MileageOp {
  final DateTime date;
  final String trip;
  final double km;
  final double? periodKmRate;
  final double settingsDefaultRate;
  const _WriteDrivingDetailOp({
    required this.date,
    required this.trip,
    required this.km,
    required this.periodKmRate,
    required this.settingsDefaultRate,
  });
}

class _ChangeRateOp extends _MileageOp {
  final double newRate;
  const _ChangeRateOp(this.newRate);
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
        // Section 7, "Инициализация нового периода": G1 must be written
        // BEFORE row 8, so writeRate always comes first here.
        engine.writeRate(o.kmRate);
        engine.writePeriodHeader(periodLabel: o.periodLabel, employeeName: o.employeeName);
        engine.initializeKilometersRow(periodEnd: o.periodEnd);
      case _WriteReceiptOp o:
        final kmTotal = engine.sumDrivingDetailsKm();
        engine.writeReceipt(
          o.receipt,
          currentKmTotal: kmTotal,
          periodKmRate: o.periodKmRate,
          settingsDefaultRate: o.settingsDefaultRate,
        );
      case _WriteDrivingDetailOp o:
        engine.writeDrivingDetail(
          date: o.date,
          trip: o.trip,
          km: o.km,
          periodKmRate: o.periodKmRate,
          settingsDefaultRate: o.settingsDefaultRate,
        );
      case _ChangeRateOp o:
        engine.changeRate(o.newRate);
    }

    req.replyPort.send(SaveXlsxPhase.writing);
    final template = Excel.decodeBytes(templateBytes);
    healMileageReportStyles(engine.excel, template, includeHiddenSheets: req.healHiddenSheets);
    final healedBytes = engine.excel.encode();
    if (healedBytes == null) {
      req.replyPort.send(StateError('excel.encode() returned null while healing cell styles'));
      return;
    }
    // The `excel`-package cell-style/merge-cell defects raw_style_patch.dart
    // repairs (font/border/fill, and cells dropped from merged ranges) are
    // workbook-global -- any write anywhere can corrupt cells on sheets
    // never touched this write, including the 5 hidden sheets. The cheap
    // raw-XML per-sheet passes here always cover every sheet, independent
    // of `healHiddenSheets` (which only gates the expensive in-memory
    // `healMileageReportStyles` full heal above -- that's the real perf
    // cost, per style_heal.dart's own doc comment, not this raw-XML pass).
    final patchedBytes = patchRawXlsxStyles(
      Uint8List.fromList(healedBytes),
      templateBytes,
      allSheets: [...mileageVisibleSheets, ...mileageHiddenSheets],
      alignmentSheets: [...mileageVisibleSheets, ...mileageHiddenSheets],
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

  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
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
    return await completer.future.timeout(_isolateTimeout,
        onTimeout: () => throw StateError('Mileage write isolate timed out after $_isolateTimeout'));
  } finally {
    isolate?.kill(priority: Isolate.immediate);
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
  required double kmRate,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final templateBytes = await _mileageTemplateBytes();
  final result = await _runMileageIsolate(
    sourceBytes: templateBytes,
    templateBytes: templateBytes,
    healHiddenSheets: true,
    op: _CreateMileagePeriod(
      periodLabel: periodLabel,
      employeeName: employeeName,
      periodEnd: periodEnd,
      kmRate: kmRate,
    ),
    onPhase: onPhase,
  );
  await logStyleWarnings('createMileagePeriod', file.uri.pathSegments.last, result.styleWarnings);
  await _atomicWrite(file, result.bytes);
}

/// Adds a receipt to [file]'s Mileage Report (section 7/8). Throws
/// [MileageReportStructureException] if the file was hand-edited outside
/// the app, [MileageReportRowsExhaustedException] if there's no room left,
/// or [XlsxIntegrityException] if the healed result fails verification.
///
/// [periodKmRate]/[settingsDefaultRate] resolve the rate for the
/// Kilometers row's Travel per section 6.2's priority rule -- pass
/// `period.kmRate` and the current Settings default respectively; the file
/// itself is still authoritative if its own `G1` is already filled.
Future<void> saveMileageReceipt(
  File file,
  ReceiptInput receipt, {
  required double? periodKmRate,
  required double settingsDefaultRate,
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
    op: _WriteReceiptOp(receipt, periodKmRate: periodKmRate, settingsDefaultRate: settingsDefaultRate),
    onPhase: onPhase,
  );
  await logStyleWarnings('saveMileageReceipt', file.uri.pathSegments.last, result.styleWarnings);
  await _atomicWrite(file, result.bytes);
}

/// Adds a trip to [file]'s Driving Details sheet and recalculates the
/// Kilometers row (section 7/9). Same exceptions as [saveMileageReceipt];
/// see it for [periodKmRate]/[settingsDefaultRate].
Future<void> saveMileageDrivingDetail(
  File file, {
  required DateTime date,
  required String trip,
  required double km,
  required double? periodKmRate,
  required double settingsDefaultRate,
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
    op: _WriteDrivingDetailOp(
      date: date,
      trip: trip,
      km: km,
      periodKmRate: periodKmRate,
      settingsDefaultRate: settingsDefaultRate,
    ),
    onPhase: onPhase,
  );
  await logStyleWarnings('saveMileageDrivingDetail', file.uri.pathSegments.last, result.styleWarnings);
  await _atomicWrite(file, result.bytes);
}

/// Changes a period file's $/km rate explicitly (section 6.2): writes `G1`
/// and recomputes the Kilometers row's Travel together, as one operation.
/// Used by both rate-change paths -- the Settings default (against the
/// calendar-current period's file) and the period form's own rate field
/// (against that specific period's file, archival or not) -- the caller
/// picks which file to target.
Future<void> changeMileagePeriodRate(
  File file, {
  required double newRate,
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
    op: _ChangeRateOp(newRate),
    onPhase: onPhase,
  );
  await logStyleWarnings('changeMileagePeriodRate', file.uri.pathSegments.last, result.styleWarnings);
  await _atomicWrite(file, result.bytes);
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

class _ClearTimesheetDayOp extends _TimesheetOp {
  final int row;
  const _ClearTimesheetDayOp(this.row);
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
      case _ClearTimesheetDayOp o:
        engine.clearDay(o.row);
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

  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _timesheetIsolateEntry,
      _TimesheetRequest(sourceBytes: sourceBytes, templateBytes: templateBytes, op: op, replyPort: port.sendPort),
      onError: errorPort.sendPort,
    );
    return await completer.future.timeout(_isolateTimeout,
        onTimeout: () => throw StateError('Timesheet write isolate timed out after $_isolateTimeout'));
  } finally {
    isolate?.kill(priority: Isolate.immediate);
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
  await _atomicWrite(file, result.bytes);
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
  await _atomicWrite(file, result.bytes);
  return result.bytes;
}

/// Clears one day's Start/Lunch/Coffee/Finish/Hours/Total (section 10) --
/// marks the day as not worked. A legitimate action distinct from
/// [saveTimesheetDay]'s validation of a filled-in day; the day is simply
/// blanked, not deleted (Item#/Date in columns A/B are untouched).
Future<Uint8List> clearTimesheetDay(
  File file, {
  required int row,
  void Function(SaveXlsxPhase)? onPhase,
}) async {
  onPhase?.call(SaveXlsxPhase.reading);
  final sourceBytes = await file.readAsBytes();
  final templateBytes = await _timesheetTemplateBytes();
  await _backupManager.backupBeforeWrite(file);
  final result = await _runTimesheetIsolate(
    sourceBytes: sourceBytes,
    templateBytes: templateBytes,
    op: _ClearTimesheetDayOp(row),
    onPhase: onPhase,
  );
  await logStyleWarnings('clearTimesheetDay', file.uri.pathSegments.last, result.styleWarnings);
  await _atomicWrite(file, result.bytes);
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

  Isolate? isolate;
  try {
    isolate = await Isolate.spawn(
      _summarizeTimesheetIsolateEntry,
      _SummarizeTimesheetRequest(sourceBytes, port.sendPort),
      onError: errorPort.sendPort,
    );
    return await completer.future.timeout(_isolateTimeout,
        onTimeout: () => throw StateError('Timesheet summary isolate timed out after $_isolateTimeout'));
  } finally {
    isolate?.kill(priority: Isolate.immediate);
    await portSub.cancel();
    await errorSub.cancel();
    port.close();
    errorPort.close();
  }
}
