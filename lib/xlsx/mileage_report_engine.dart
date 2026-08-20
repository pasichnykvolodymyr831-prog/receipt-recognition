import 'dart:typed_data';

import 'package:excel/excel.dart';

import '../utils/number_input.dart';
import 'cell_value_utils.dart';
import 'xlsx_rels_compat.dart';

/// Thrown when the sheet's row 8-27 data range is full and a new receipt
/// (or the Kilometers row) has nowhere left to go. The caller must show the
/// "edit the file directly" warning from section 7 and abort the write.
class MileageReportRowsExhaustedException implements Exception {
  const MileageReportRowsExhaustedException();
}

/// Thrown when a required sheet or header cell is missing, i.e. the file
/// was hand-edited outside the app enough that the app can no longer trust
/// the fixed cell map from section 6. Section 13.1: don't write blindly.
class MileageReportStructureException implements Exception {
  final String message;
  const MileageReportStructureException(this.message);
  @override
  String toString() => 'MileageReportStructureException: $message';
}

/// Thrown when a row the write algorithm requires to be empty (the blank
/// gap row above Kilometers, or -- before the first receipt -- either of
/// the two candidate rows) already has content in it. Section 7's algorithm
/// maintains that invariant itself; a violation means a prior write was
/// interrupted or the algorithm has a bug, not that the user hand-edited
/// the file (section 1a: the working file isn't user-editable). Nothing is
/// written when this is thrown -- caller must show a blocking message and
/// leave the file untouched.
class MileageReportRowOccupiedException implements Exception {
  final List<int> rows;
  const MileageReportRowOccupiedException(this.rows);
  @override
  String toString() =>
      'MileageReportRowOccupiedException: row(s) ${rows.join(", ")} on "${MileageReportEngine.sheetName}" expected to be empty but are not';
}

class ReceiptInput {
  final DateTime? date;
  final String? description;
  final double? subtotal;
  final double? gst;

  const ReceiptInput({this.date, this.description, this.subtotal, this.gst});
}

/// A previously-saved receipt read back from the sheet (section 14): the
/// same fields as [ReceiptInput], plus the row it lives on -- needed so an
/// edit can write back to that exact row instead of going through
/// [MileageReportEngine.writeReceipt]'s Kilometers-row shift algorithm.
class ReceiptRecord {
  final int row;
  final DateTime? date;
  final String? description;
  final double? subtotal;
  final double? gst;

  const ReceiptRecord({required this.row, this.date, this.description, this.subtotal, this.gst});
}

/// A previously-saved Driving Details trip read back from the sheet
/// (section 14), with its row for the same reason as [ReceiptRecord].
class DrivingDetailRecord {
  final int row;
  final DateTime? date;
  final String trip;
  final double? km;

  const DrivingDetailRecord({required this.row, this.date, required this.trip, this.km});
}

/// Read/write engine for the "Truman Homes" and "Driving Details" sheets of
/// the Mileage Report workbook, implementing the exact cell map (section 6)
/// and the Kilometers-row algorithm (section 7). Every other sheet (the 5
/// hidden ones) is never touched.
class MileageReportEngine {
  static const sheetName = 'Truman Homes';
  static const drivingDetailsSheetName = 'Driving Details';

  static const firstDataRow = 8; // 1-based Excel row
  static const lastDataRow = 27;

  static const firstDrivingRow = 2;
  static const lastDrivingRow = 18;

  final Excel excel;

  MileageReportEngine(this.excel) {
    _assertStructure();
  }

  /// Normalizes package-root-relative `.rels` targets (a quirk of templates
  /// hand-edited and re-saved through openpyxl -- see
  /// xlsx_rels_compat.dart) before decoding, so every caller gets a
  /// template the `excel` package can actually open, not just the
  /// production write pipeline that happened to normalize separately.
  factory MileageReportEngine.fromBytes(List<int> bytes) {
    return MileageReportEngine(Excel.decodeBytes(normalizeXlsxRelationshipTargets(Uint8List.fromList(bytes))));
  }

  List<int> save() {
    final bytes = excel.encode();
    if (bytes == null) {
      throw StateError('excel.encode() returned null');
    }
    return bytes;
  }

  void _assertStructure() {
    if (!excel.sheets.containsKey(sheetName)) {
      throw MileageReportStructureException('Sheet "$sheetName" not found');
    }
    if (!excel.sheets.containsKey(drivingDetailsSheetName)) {
      throw MileageReportStructureException(
          'Sheet "$drivingDetailsSheetName" not found');
    }
    final sheet = excel.sheets[sheetName]!;
    final headerRow6 = [
      'Date',
      'Description',
      'Office',
      'Materials',
      'Travel',
      'Phone',
      'Meals',
      'Showhome',
    ];
    for (var col = 0; col < headerRow6.length; col++) {
      final cell = sheet.cell(CellIndex.indexByColumnRow(columnIndex: col, rowIndex: 5));
      final text = textOf(cell.value);
      if (text.trim().isEmpty) {
        throw MileageReportStructureException(
            'Expected header at ${_a1(col, 5)}, found empty cell. '
            'The file may have been edited outside the app.');
      }
    }
  }

  Sheet get _sheet => excel.sheets[sheetName]!;
  Sheet get _drivingSheet => excel.sheets[drivingDetailsSheetName]!;

  Data _cell(Sheet sheet, String a1) => sheet.cell(CellIndex.indexByString(a1));

  /// Writes M3 (period label) and B3 (employee name). Called once when a
  /// new period's file is created (section 5).
  void writePeriodHeader({required String periodLabel, required String employeeName}) {
    setCellValue(_sheet, 'M3', TextCellValue(periodLabel));
    setCellValue(_sheet, 'B3', TextCellValue(employeeName));
  }

  /// Rewrites just B3 (employee name) on an already-existing file (Пакет 9:
  /// a Settings name change propagates to the current period's file
  /// immediately). Doesn't touch M3 (period label), unlike
  /// [writePeriodHeader], which is only ever called once at creation.
  void updateEmployeeName(String employeeName) {
    setCellValue(_sheet, 'B3', TextCellValue(employeeName));
  }

  /// Initializes row 8 as the Kilometers row on a freshly created period
  /// file, before any receipts exist (section 7, "Инициализация нового
  /// периода"). Must be called AFTER [writeRate] -- not because E8 (always
  /// 0 here, 0 times any rate) actually depends on G1's value, but to match
  /// the documented write order so this stays correct if E8's computation
  /// ever stops being a trivial constant.
  void initializeKilometersRow({required DateTime periodEnd}) {
    setCellValue(_sheet, 'A8', DateCellValue.fromDateTime(periodEnd));
    setCellValue(_sheet, 'B8', TextCellValue('Kilometers (0)'));
    setCellValue(_sheet, 'E8', const DoubleCellValue(0));
  }

  /// Reads the $/km rate from Driving Details' `G1` (section 6.2), or null
  /// if the cell is empty/absent -- the state every file created before
  /// this feature existed is in, and the signal [resolveAndSyncRate] uses
  /// to know it needs to fall back and self-heal the cell.
  double? readRate() => numberOf(_cell(_drivingSheet, 'G1').value);

  /// Writes [rate] into Driving Details' `G1` as a plain number, never a
  /// formula (section 6.2) -- the `=SUM(C{r}*$G$1)` formula in column D
  /// reads it from here.
  void writeRate(double rate) => setCellValue(_drivingSheet, 'G1', DoubleCellValue(rate));

  /// Implements section 6.2's rate-authority rule for a file that already
  /// exists (cases 2 and 3 of "Приоритет источников ставки" -- case 1, "the
  /// file doesn't exist yet", is resolved by the caller before an engine
  /// for it can even exist, at period-creation time). `G1` is authoritative
  /// whenever it's filled (case 2); when it's empty -- true of every file
  /// created before this feature existed, including old-template files --
  /// resolve via [periodKmRate] falling back to [settingsDefaultRate], and
  /// immediately write the result into `G1` so the file behaves like a
  /// new-template file from here on (case 3). Never read `G1` blindly: an
  /// empty rate would zero out every future Travel calculation silently.
  double resolveAndSyncRate({required double? periodKmRate, required double settingsDefaultRate}) {
    final g1 = readRate();
    if (g1 != null) return g1;
    final resolved = periodKmRate ?? settingsDefaultRate;
    writeRate(resolved);
    return resolved;
  }

  /// Compares two rates with tolerance, never `==` (section 6.2, last
  /// bullet): a rate that round-trips through the XML can pick up a float
  /// tail (the template shipped with `0.5600000000000001` at one point),
  /// which would make an exact-equality comparison flag agreement as drift
  /// and rewrite the file on every launch.
  static bool ratesEqual(double a, double b) => (a - b).abs() < 1e-9;

  /// Explicit rate change (section 6.2): writes the new rate into `G1` and
  /// recomputes the Kilometers row's Travel to match, as a single atomic
  /// operation -- distinct from [resolveAndSyncRate], which only ever
  /// writes `G1` when it finds it empty. Used by both rate-change paths
  /// (Settings default, or the period form's own rate field) -- the caller
  /// decides which period's file this runs against.
  void changeRate(double newRate) {
    final kmRow = findKilometersRow();
    if (kmRow == null) {
      throw const MileageReportStructureException(
          'No "Kilometers (" row found -- period file was not initialized correctly.');
    }
    writeRate(newRate);
    _writeKilometersRowFields(kmRow, kmTotal: sumDrivingDetailsKm(), rate: newRate);
  }

  void _writeKilometersRowFields(int kmRow, {required double kmTotal, required double rate}) {
    setCellValue(_sheet, 'B$kmRow', TextCellValue('Kilometers (${formatKmCount(kmTotal)})'));
    setCellValue(_sheet, 'E$kmRow', DoubleCellValue(round2(kmTotal * rate)));
  }

  /// Finds the row (1-based) whose Description (column B) starts with
  /// "Kilometers (", by scanning the live sheet content -- never cached,
  /// per section 7's resilience note. Returns null if not found (should not
  /// happen on a properly-initialized period file). Throws
  /// [MileageReportStructureException] if MORE than one such row exists
  /// (section 13.1a) -- that state can only arise from hand-editing the
  /// marker text or an internal write bug, never from normal app use, and
  /// guessing which one is "real" risks double-counting kilometers in the
  /// report totals. The working file isn't user-editable (section 1a), so
  /// the only path back for the user is restoring from the automatic backup.
  int? findKilometersRow() {
    final rows = _findAllKilometersRows();
    if (rows.isEmpty) return null;
    if (rows.length > 1) {
      throw MileageReportStructureException(
          'Multiple "Kilometers (" rows found on sheet "$sheetName" (rows ${rows.join(", ")}). '
          'This should not happen during normal use -- restore the period file from its most recent backup.');
    }
    return rows.single;
  }

  List<int> _findAllKilometersRows() {
    final rows = <int>[];
    for (var row = firstDataRow; row <= lastDataRow; row++) {
      final text = textOf(_sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row - 1)).value);
      if (text.startsWith('Kilometers (')) {
        rows.add(row);
      }
    }
    return rows;
  }

  /// The columns the Kilometers-row transfer/clear algorithm (section 7) is
  /// defined over: every column the app is ever allowed to touch on this
  /// sheet, minus the formula columns I/L.
  static const _rowColumns = ['A', 'B', 'C', 'D', 'E', 'F', 'G', 'H', 'K'];

  bool _isRowEmpty(int row) {
    for (final col in _rowColumns) {
      if (!isEmptyCell(_cell(_sheet, '$col$row').value)) return false;
    }
    return true;
  }

  /// Writes a new receipt into the sheet, shifting the Kilometers row (and
  /// its accompanying blank gap row) down by one position, exactly per the
  /// algorithm in section 7.
  ///
  /// [currentKmTotal] is the up-to-date sum of the Driving Details KM
  /// column, used to recompute the Kilometers row's Description text as it
  /// moves.
  ///
  /// Throws [MileageReportRowOccupiedException] if the gap row (or, before
  /// the first receipt, either candidate row) already has content -- an
  /// internal-consistency guard, not a user-facing validation (section 1a).
  /// Throws [MileageReportRowsExhaustedException] if there is no room left;
  /// in either case nothing is written at all.
  ///
  /// [periodKmRate]/[settingsDefaultRate] feed [resolveAndSyncRate] (section
  /// 6.2) to get the rate for recomputing the Kilometers row's Travel as it
  /// shifts -- default to null/0.56 so callers that don't care about rate
  /// behavior (most unit tests, which always source the engine from the
  /// bundled template where `G1` already has a value) don't need to pass
  /// them; every real write path (safe_xlsx_write.dart) always passes
  /// explicit values sourced from the actual period/Settings.
  void writeReceipt(
    ReceiptInput receipt, {
    required double currentKmTotal,
    double? periodKmRate,
    double settingsDefaultRate = 0.56,
  }) {
    final kmRow = findKilometersRow();
    if (kmRow == null) {
      throw const MileageReportStructureException(
          'No "Kilometers (" row found -- period file was not initialized correctly.');
    }
    final rate = resolveAndSyncRate(periodKmRate: periodKmRate, settingsDefaultRate: settingsDefaultRate);

    if (kmRow == firstDataRow) {
      const newKmRow = firstDataRow + 2; // row 10
      const gapCandidateRow = firstDataRow + 1; // row 9
      final occupied = <int>[
        if (!_isRowEmpty(gapCandidateRow)) gapCandidateRow,
        if (!_isRowEmpty(newKmRow)) newKmRow,
      ];
      if (occupied.isNotEmpty) {
        throw MileageReportRowOccupiedException(occupied);
      }
      _moveKilometersRow(fromRow: kmRow, toRow: newKmRow, kmTotal: currentKmTotal, rate: rate);
      _clearRow(kmRow); // row 8: content already copied to row 10
      _clearRow(gapCandidateRow); // row 9 becomes the gap (already verified empty)
      _writeReceiptRow(firstDataRow, receipt);
      return;
    }

    final gapRow = kmRow - 1;
    if (!_isRowEmpty(gapRow)) {
      throw MileageReportRowOccupiedException([gapRow]);
    }
    final newKmRow = kmRow + 1;
    if (newKmRow > lastDataRow) {
      throw const MileageReportRowsExhaustedException();
    }
    _moveKilometersRow(fromRow: kmRow, toRow: newKmRow, kmTotal: currentKmTotal, rate: rate);
    _clearRow(kmRow); // old km row becomes the new gap; content already copied
    _writeReceiptRow(gapRow, receipt);
  }

  /// Copies every column the app manages on this sheet (section 6.1: A, C,
  /// D, F, G, H, K) from [fromRow] to [toRow] as-is, recomputes the
  /// Kilometers marker's Description AND Travel (E) at its new position
  /// (section 7: "E пересчитать как round(N × rate, 2)" -- E is NOT simply
  /// carried over, unlike every other column). Does NOT clear [fromRow] --
  /// callers do that via [_clearRow] once the copy is safely on the new row
  /// (section 7: transfer whole, THEN clear the source -- unconditionally,
  /// not just the columns the app happens to use today, so this stays
  /// correct even if C/F/G/H ever hold something).
  void _moveKilometersRow({
    required int fromRow,
    required int toRow,
    required double kmTotal,
    required double rate,
  }) {
    final values = {for (final col in _rowColumns) col: _cell(_sheet, '$col$fromRow').value};

    setCellValue(_sheet, 'A$toRow', values['A']);
    setCellValue(_sheet, 'C$toRow', values['C']);
    setCellValue(_sheet, 'D$toRow', values['D']);
    setCellValue(_sheet, 'F$toRow', values['F']);
    setCellValue(_sheet, 'G$toRow', values['G']);
    setCellValue(_sheet, 'H$toRow', values['H']);
    setCellValue(_sheet, 'K$toRow', values['K']);
    _writeKilometersRowFields(toRow, kmTotal: kmTotal, rate: rate);
  }

  void _writeReceiptRow(int row, ReceiptInput receipt) {
    if (receipt.date != null) {
      setCellValue(_sheet, 'A$row', DateCellValue.fromDateTime(receipt.date!));
    }
    if (receipt.description != null && receipt.description!.trim().isNotEmpty) {
      setCellValue(_sheet, 'B$row', TextCellValue(receipt.description!));
    }
    if (receipt.subtotal != null) {
      // Rounded again here (belt-and-suspenders on top of the screen's own
      // rounding, section 8) so any direct caller of the engine -- tests,
      // future callers -- can't accidentally write a long float tail.
      setCellValue(_sheet, 'D$row', DoubleCellValue(round2(receipt.subtotal!)));
    }
    if (receipt.gst != null) {
      setCellValue(_sheet, 'K$row', DoubleCellValue(round2(receipt.gst!)));
    }
  }

  /// Clears every column the Kilometers-row algorithm is defined over (A,
  /// B, C, D, E, F, G, H, K) on [row]. Columns I and L (formulas) are left
  /// untouched. This is the one place the app ever clears C/F/G/H -- normal
  /// receipt rows never have those touched (section 6.1) -- and it's safe
  /// here specifically because [_clearRow] is only ever called on a row
  /// whose content has already been copied elsewhere by [_moveKilometersRow]
  /// (section 7: unconditional whole-row transfer-then-clear).
  void _clearRow(int row) {
    for (final col in _rowColumns) {
      setCellValue(_sheet, '$col$row', null);
    }
  }

  /// Recomputes the Kilometers row's Description AND Travel from [kmTotal]
  /// without moving the row or touching its Date cell (section 7, "Алгоритм
  /// при изменении Driving Details"). See [writeReceipt] for
  /// [periodKmRate]/[settingsDefaultRate]'s defaults and why they exist.
  void recalcKilometersRow({
    required double kmTotal,
    double? periodKmRate,
    double settingsDefaultRate = 0.56,
  }) {
    final kmRow = findKilometersRow();
    if (kmRow == null) {
      throw const MileageReportStructureException(
          'No "Kilometers (" row found -- period file was not initialized correctly.');
    }
    final rate = resolveAndSyncRate(periodKmRate: periodKmRate, settingsDefaultRate: settingsDefaultRate);
    _writeKilometersRowFields(kmRow, kmTotal: kmTotal, rate: rate);
  }

  /// Sums the Driving Details KM column (C2:C18) for the current period.
  double sumDrivingDetailsKm() {
    var total = 0.0;
    for (var row = firstDrivingRow; row <= lastDrivingRow; row++) {
      final value = numberOf(_cell(_drivingSheet, 'C$row').value);
      if (value != null) total += value;
    }
    return total;
  }

  /// Finds the first free row (2-18) in Driving Details, i.e. the first row
  /// where A, B and C are all empty. Returns null if the sheet is full.
  int? findFirstFreeDrivingDetailsRow() {
    for (var row = firstDrivingRow; row <= lastDrivingRow; row++) {
      final a = _cell(_drivingSheet, 'A$row').value;
      final b = _cell(_drivingSheet, 'B$row').value;
      final c = _cell(_drivingSheet, 'C$row').value;
      if (isEmptyCell(a) && isEmptyCell(b) && isEmptyCell(c)) {
        return row;
      }
    }
    return null;
  }

  /// Writes a Driving Details entry (section 9) into the first free row and
  /// recalculates the Kilometers row's Description and Travel to match. See
  /// [writeReceipt] for [periodKmRate]/[settingsDefaultRate]'s defaults.
  ///
  /// Throws [MileageReportRowsExhaustedException] if the sheet is full;
  /// nothing is written in that case.
  void writeDrivingDetail({
    required DateTime date,
    required String trip,
    required double km,
    double? periodKmRate,
    double settingsDefaultRate = 0.56,
  }) {
    final row = findFirstFreeDrivingDetailsRow();
    if (row == null) {
      throw const MileageReportRowsExhaustedException();
    }
    setCellValue(_drivingSheet, 'A$row', DateCellValue.fromDateTime(date));
    setCellValue(_drivingSheet, 'B$row', TextCellValue(trip));
    // Rounded again here on top of the screen's own rounding (section 9) --
    // same belt-and-suspenders reasoning as writeReceipt's Subtotal/GST.
    setCellValue(_drivingSheet, 'C$row', DoubleCellValue(round2(km)));

    recalcKilometersRow(
      kmTotal: sumDrivingDetailsKm(),
      periodKmRate: periodKmRate,
      settingsDefaultRate: settingsDefaultRate,
    );
  }

  /// Lists every already-saved receipt (section 14): rows 8-27 excluding
  /// the Kilometers row, included only when at least one of the
  /// app-managed fields (Date/Description/Subtotal/GST) is filled -- the
  /// same two conditions section 14 requires, so a row that's merely
  /// styled but never written to isn't mistaken for a real receipt.
  List<ReceiptRecord> listReceipts() {
    final result = <ReceiptRecord>[];
    for (var row = firstDataRow; row <= lastDataRow; row++) {
      final descriptionText = textOf(_cell(_sheet, 'B$row').value);
      if (descriptionText.startsWith('Kilometers (')) continue;

      final date = dateOf(_cell(_sheet, 'A$row').value);
      final description = descriptionText.isEmpty ? null : descriptionText;
      final subtotal = numberOf(_cell(_sheet, 'D$row').value);
      final gst = numberOf(_cell(_sheet, 'K$row').value);
      if (date == null && description == null && subtotal == null && gst == null) continue;

      result.add(ReceiptRecord(row: row, date: date, description: description, subtotal: subtotal, gst: gst));
    }
    return result;
  }

  /// Lists every already-saved Driving Details trip (section 14): rows
  /// 2-18, included when at least one of Date/Trip/KM is filled.
  List<DrivingDetailRecord> listDrivingDetails() {
    final result = <DrivingDetailRecord>[];
    for (var row = firstDrivingRow; row <= lastDrivingRow; row++) {
      final date = dateOf(_cell(_drivingSheet, 'A$row').value);
      final tripText = textOf(_cell(_drivingSheet, 'B$row').value);
      final km = numberOf(_cell(_drivingSheet, 'C$row').value);
      if (date == null && tripText.isEmpty && km == null) continue;

      result.add(DrivingDetailRecord(row: row, date: date, trip: tripText, km: km));
    }
    return result;
  }

  /// Overwrites an already-saved receipt row in place (section 14) -- no
  /// Kilometers-row search, no shift, unlike [writeReceipt]. Every field is
  /// written unconditionally, including clearing it when null/empty, unlike
  /// [_writeReceiptRow]'s skip-when-absent semantics (correct for ADD,
  /// where "not provided" means "leave the already-blank cell alone"; wrong
  /// for EDIT, where "not provided" means "the user cleared it").
  void updateReceipt(int row, ReceiptInput receipt) {
    if (row < firstDataRow || row > lastDataRow) {
      throw RangeError.value(row, 'row', 'Must be between $firstDataRow and $lastDataRow');
    }
    if (textOf(_cell(_sheet, 'B$row').value).startsWith('Kilometers (')) {
      throw ArgumentError.value(row, 'row', 'Refusing to overwrite the Kilometers row as a receipt');
    }
    setCellValue(_sheet, 'A$row', receipt.date == null ? null : DateCellValue.fromDateTime(receipt.date!));
    final description = receipt.description?.trim() ?? '';
    setCellValue(_sheet, 'B$row', description.isEmpty ? null : TextCellValue(description));
    setCellValue(_sheet, 'D$row', receipt.subtotal == null ? null : DoubleCellValue(round2(receipt.subtotal!)));
    setCellValue(_sheet, 'K$row', receipt.gst == null ? null : DoubleCellValue(round2(receipt.gst!)));
  }

  /// Overwrites an already-saved Driving Details row in place (section 14)
  /// -- no free-row search, unlike [writeDrivingDetail]. Recalculates the
  /// Kilometers row afterward (Description + Travel), since editing KM
  /// changes the period-wide total that row summarizes.
  void updateDrivingDetail(
    int row, {
    required DateTime date,
    required String trip,
    required double km,
    double? periodKmRate,
    double settingsDefaultRate = 0.56,
  }) {
    if (row < firstDrivingRow || row > lastDrivingRow) {
      throw RangeError.value(row, 'row', 'Must be between $firstDrivingRow and $lastDrivingRow');
    }
    setCellValue(_drivingSheet, 'A$row', DateCellValue.fromDateTime(date));
    setCellValue(_drivingSheet, 'B$row', TextCellValue(trip));
    setCellValue(_drivingSheet, 'C$row', DoubleCellValue(round2(km)));

    recalcKilometersRow(
      kmTotal: sumDrivingDetailsKm(),
      periodKmRate: periodKmRate,
      settingsDefaultRate: settingsDefaultRate,
    );
  }
}

String _a1(int columnIndex, int rowIndex) {
  return CellIndex.indexByColumnRow(columnIndex: columnIndex, rowIndex: rowIndex).cellId;
}
