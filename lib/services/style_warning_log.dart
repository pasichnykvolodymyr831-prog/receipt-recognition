import 'dart:io';

import 'package:flutter/foundation.dart' show debugPrint;
import 'package:path_provider/path_provider.dart';

/// Persists non-fatal style-integrity warnings (IntegrityReport.styleWarnings
/// in xlsx/excel_integrity.dart) to a durable log file, in addition to
/// printing them.
///
/// Under normal operation this should stay empty: style_heal.dart reapplies
/// the template's style to every managed cell before the check runs, so the
/// only expected residual warning is the known, intentionally-skipped
/// text-in-a-time-formatted-cell number_format quirk (see
/// _expectStylePreserved in excel_integrity.dart), which never reaches here.
/// If something else ever does, this is the one place to look -- a bare
/// debugPrint would only be visible while a debugger happens to be attached,
/// which is exactly how the original style-loss bug went unnoticed for as
/// long as it did.
Future<void> logStyleWarnings(String source, String targetFileName, List<String> warnings) async {
  if (warnings.isEmpty) return;

  debugPrint('$source: style warnings (non-fatal) for $targetFileName: ${warnings.join("; ")}');

  try {
    final dir = await getApplicationDocumentsDirectory();
    final log = File('${dir.path}/style_warnings.log');
    final entry = '${DateTime.now().toIso8601String()} $source $targetFileName: ${warnings.join("; ")}\n';
    await log.writeAsString(entry, mode: FileMode.append, flush: true);
  } catch (e) {
    // Best-effort only -- a logging failure must never block the actual write.
    debugPrint('logStyleWarnings: failed to persist to style_warnings.log: $e');
  }
}
