// Regression test for a real template-authoring bug (found 2026-08-18): the
// Timesheet template's <cols> block set custom widths for Start Time (C)
// and Finish Time (F) -- both short single-time strings like "8am" -- but
// never for Lunch Break (D) or Coffee Break (E), which hold longer
// "HHMM-HHMM" range strings like "1200-1230". Left at the sheet's narrow
// default width (~8.5 chars), that text overflowed past the cell boundary
// on every row with a lunch/coffee entry, visually painting over the D/E
// (and E/F) grid line -- reported by the user as "the vertical border
// between D and E doesn't show, right after 1200-1230, on every such row."
// Fixed directly in the template (assets/templates + _handoff, kept in
// sync, same pattern as the earlier G1-float-tail template fix) by giving
// D and E the same width as C/F. This test locks that in so a future
// template swap can't silently reintroduce the overflow.
import 'dart:io';
import 'dart:typed_data';

import 'package:excel/excel.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/xlsx/xlsx_rels_compat.dart';

const timesheetTemplatePath = 'assets/templates/Truman_Homes_Timesheet_TEMPLATE.xlsx';

void main() {
  test('Lunch Break (D) and Coffee Break (E) columns are at least as wide as Start/Finish Time (C/F)', () {
    final bytes =
        normalizeXlsxRelationshipTargets(Uint8List.fromList(File(timesheetTemplatePath).readAsBytesSync()));
    final excel = Excel.decodeBytes(bytes);
    final sheet = excel.sheets['Sheet1']!;

    // Column indices are 0-based: A=0, B=1, C=2, D=3, E=4, F=5.
    final widthC = sheet.getColumnWidth(2);
    final widthD = sheet.getColumnWidth(3);
    final widthE = sheet.getColumnWidth(4);
    final widthF = sheet.getColumnWidth(5);

    expect(widthD, greaterThanOrEqualTo(widthC),
        reason: 'Lunch Break holds longer "HHMM-HHMM" text than Start Time\'s single time -- must not be narrower');
    expect(widthE, greaterThanOrEqualTo(widthF),
        reason: 'Coffee Break holds longer "HHMM-HHMM" text than Finish Time\'s single time -- must not be narrower');

    // The specific real-world value that overflowed: "1200-1230" is 9
    // characters; the sheet's own defaultColWidth (~8.5) is narrower than
    // that, so D/E must have an explicit customWidth wider than the default.
    expect(widthD, greaterThan(9.0));
    expect(widthE, greaterThan(9.0));
  });

  test('_handoff and assets copies of the Timesheet template stay byte-identical (section 0: sync check)', () {
    final handoffBytes = File('_handoff/Truman_Homes_Timesheet_TEMPLATE.xlsx').readAsBytesSync();
    final assetsBytes = File(timesheetTemplatePath).readAsBytesSync();
    expect(assetsBytes, handoffBytes);
  });
}
