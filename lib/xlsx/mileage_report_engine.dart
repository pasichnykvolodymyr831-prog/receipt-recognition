import 'package:excel/excel.dart';

import 'cell_value_utils.dart';

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

class ReceiptInput {
  final DateTime? date;
  final String? description;
  final double? subtotal;
  final double? gst;

  const ReceiptInput({this.date, this.description, this.subtotal, this.gst});
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

  factory MileageReportEngine.fromBytes(List<int> bytes) {
    return MileageReportEngine(Excel.decodeBytes(bytes));
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

  /// Initializes row 8 as the Kilometers row on a freshly created period
  /// file, before any receipts exist (section 7, "Инициализация нового периода").
  void initializeKilometersRow({required DateTime periodEnd}) {
    setCellValue(_sheet, 'A8', DateCellValue.fromDateTime(periodEnd));
    setCellValue(_sheet, 'B8', TextCellValue('Kilometers (0)'));
  }

  /// Finds the row (1-based) whose Description (column B) starts with
  /// "Kilometers (", by scanning the live sheet content -- never cached,
  /// per section 7's resilience note. Returns null if not found (should not
  /// happen on a properly-initialized period file).
  int? findKilometersRow() {
    for (var row = firstDataRow; row <= lastDataRow; row++) {
      final text = textOf(_sheet.cell(CellIndex.indexByColumnRow(columnIndex: 1, rowIndex: row - 1)).value);
      if (text.startsWith('Kilometers (')) {
        return row;
      }
    }
    return null;
  }

  /// Writes a new receipt into the sheet, shifting the Kilometers row (and
  /// its accompanying blank gap row) down by one position, exactly per the
  /// algorithm in section 7.
  ///
  /// [currentKmTotal] is the up-to-date sum of the Driving Details KM
  /// column, used to recompute the Kilometers row's Description text as it
  /// moves.
  ///
  /// Throws [MileageReportRowsExhaustedException] if there is no room left;
  /// in that case nothing is written at all.
  void writeReceipt(ReceiptInput receipt, {required double currentKmTotal}) {
    final kmRow = findKilometersRow();
    if (kmRow == null) {
      throw const MileageReportStructureException(
          'No "Kilometers (" row found -- period file was not initialized correctly.');
    }

    if (kmRow == firstDataRow) {
      const newKmRow = firstDataRow + 2; // row 10
      _moveKilometersRow(fromRow: kmRow, toRow: newKmRow, kmTotal: currentKmTotal);
      _clearRow(firstDataRow + 1); // row 9 becomes the gap
      _writeReceiptRow(firstDataRow, receipt);
      return;
    }

    final gapRow = kmRow - 1;
    final newKmRow = kmRow + 1;
    if (newKmRow > lastDataRow) {
      throw const MileageReportRowsExhaustedException();
    }
    _moveKilometersRow(fromRow: kmRow, toRow: newKmRow, kmTotal: currentKmTotal);
    _clearRow(kmRow); // old km row becomes the new gap
    _writeReceiptRow(gapRow, receipt);
  }

  void _moveKilometersRow({required int fromRow, required int toRow, required double kmTotal}) {
    final travelValue = _cell(_sheet, 'E$fromRow').value;
    final dateValue = _cell(_sheet, 'A$fromRow').value;

    setCellValue(_sheet, 'A$toRow', dateValue);
    setCellValue(_sheet, 'B$toRow', TextCellValue('Kilometers (${formatKmCount(kmTotal)})'));
    setCellValue(_sheet, 'E$toRow', travelValue);

    // The source row is about to be reused (either as the new receipt row
    // or as the new gap row) -- it must not keep the old "Kilometers (...)"
    // marker text, or findKilometersRow() would match it as well as the
    // real (moved) row.
    setCellValue(_sheet, 'A$fromRow', null);
    setCellValue(_sheet, 'B$fromRow', null);
    setCellValue(_sheet, 'E$fromRow', null);
  }

  void _writeReceiptRow(int row, ReceiptInput receipt) {
    if (receipt.date != null) {
      setCellValue(_sheet, 'A$row', DateCellValue.fromDateTime(receipt.date!));
    }
    if (receipt.description != null && receipt.description!.trim().isNotEmpty) {
      setCellValue(_sheet, 'B$row', TextCellValue(receipt.description!));
    }
    if (receipt.subtotal != null) {
      setCellValue(_sheet, 'D$row', DoubleCellValue(receipt.subtotal!));
    }
    if (receipt.gst != null) {
      setCellValue(_sheet, 'K$row', DoubleCellValue(receipt.gst!));
    }
  }

  /// Clears columns A, B, D, E, K of [row] (everything the app is allowed
  /// to touch). Columns I and L (formulas) and C/F/G/H (always unused) are
  /// left untouched.
  void _clearRow(int row) {
    setCellValue(_sheet, 'A$row', null);
    setCellValue(_sheet, 'B$row', null);
    setCellValue(_sheet, 'D$row', null);
    setCellValue(_sheet, 'E$row', null);
    setCellValue(_sheet, 'K$row', null);
  }

  /// Recomputes the Kilometers row's Description from [kmTotal] without
  /// moving the row or touching its Date/Travel cells (section 7, "Алгоритм
  /// при изменении Driving Details").
  void recalcKilometersDescription({required double kmTotal}) {
    final kmRow = findKilometersRow();
    if (kmRow == null) {
      throw const MileageReportStructureException(
          'No "Kilometers (" row found -- period file was not initialized correctly.');
    }
    setCellValue(_sheet, 'B$kmRow', TextCellValue('Kilometers (${formatKmCount(kmTotal)})'));
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
  /// recalculates the Kilometers row's Description to match.
  ///
  /// Throws [MileageReportRowsExhaustedException] if the sheet is full;
  /// nothing is written in that case.
  void writeDrivingDetail({required DateTime date, required String trip, required double km}) {
    final row = findFirstFreeDrivingDetailsRow();
    if (row == null) {
      throw const MileageReportRowsExhaustedException();
    }
    setCellValue(_drivingSheet, 'A$row', DateCellValue.fromDateTime(date));
    setCellValue(_drivingSheet, 'B$row', TextCellValue(trip));
    setCellValue(_drivingSheet, 'C$row', DoubleCellValue(km));

    recalcKilometersDescription(kmTotal: sumDrivingDetailsKm());
  }
}

String _a1(int columnIndex, int rowIndex) {
  return CellIndex.indexByColumnRow(columnIndex: columnIndex, rowIndex: rowIndex).cellId;
}
