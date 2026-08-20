import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_strings.dart';
import '../models/mileage_cycle.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
import '../services/receipt_parser.dart';
import '../services/safe_xlsx_write.dart';
import '../services/settings_repository.dart';
import '../utils/number_input.dart';
import '../utils/text_input.dart';
import '../utils/time_format.dart';
import '../xlsx/mileage_report_engine.dart';

enum _EntryMode { none, ocr, manual }

class AddReceiptScreen extends StatefulWidget {
  final PayrollPeriod period;

  /// When set, this screen edits an already-saved receipt in place
  /// (section 14) instead of adding a new one -- opens straight into the
  /// confirm form, prefilled, with no OCR/manual entry choice.
  final ReceiptRecord? existing;

  const AddReceiptScreen({super.key, required this.period, this.existing});

  @override
  State<AddReceiptScreen> createState() => _AddReceiptScreenState();
}

class _AddReceiptScreenState extends State<AddReceiptScreen> {
  _EntryMode _mode = _EntryMode.none;
  bool _editing = false;
  bool _busy = false;
  SaveXlsxPhase? _savePhase;

  DateTime? _date;
  double? _subtotal;
  double? _gst;
  final _descriptionController = TextEditingController();
  final _subtotalController = TextEditingController();
  final _gstController = TextEditingController();

  // Section 8: Date, Subtotal and GST are required -- these hold the
  // per-field message shown next to the offending field when "Save" is
  // pressed with one of them missing/unparseable, cleared as the user
  // edits.
  String? _dateError;
  String? _subtotalError;
  String? _gstError;

  /// Resolved once in [initState] and gates the whole screen (not just the
  /// moment of saving) -- so the user doesn't walk through OCR/manual entry
  /// only to discover at Save time that [widget.period] isn't paired into a
  /// Mileage cycle yet (`MileageCycle`, whimsical-booping-salamander.md
  /// Пакет 3).
  late Future<MileageCycle?> _cycleFuture;

  @override
  void initState() {
    super.initState();
    _cycleFuture = _resolveCycle();
    final existing = widget.existing;
    if (existing != null) {
      _mode = _EntryMode.manual;
      _editing = true;
      _date = existing.date;
      _subtotal = existing.subtotal;
      _gst = existing.gst;
      _descriptionController.text = existing.description ?? '';
      _subtotalController.text = existing.subtotal?.toStringAsFixed(2) ?? '';
      _gstController.text = existing.gst?.toStringAsFixed(2) ?? '';
    }
  }

  @override
  void dispose() {
    _descriptionController.dispose();
    _subtotalController.dispose();
    _gstController.dispose();
    super.dispose();
  }

  Future<MileageCycle?> _resolveCycle() async {
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    return periodRepo.mileageCycleFor(widget.period, periods);
  }

  Future<void> _pickAndScan(ImageSource source) async {
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: source, imageQuality: 85);
      if (!mounted) return;
      if (photo == null) {
        setState(() => _busy = false);
        return;
      }

      List<OcrLine> lines = [];
      try {
        final inputImage = InputImage.fromFilePath(photo.path);
        final recognizer = TextRecognizer(script: TextRecognitionScript.latin);
        try {
          final result = await recognizer.processImage(inputImage);
          lines = result.blocks
              .expand((b) => b.lines)
              .map((l) => OcrLine(l.text, l.boundingBox.top, l.boundingBox.bottom))
              .toList();
        } finally {
          await recognizer.close();
        }
      } finally {
        // The photo is only ever used in memory for OCR -- delete the
        // temp file image_picker created as soon as recognition is done.
        final file = File(photo.path);
        if (await file.exists()) await file.delete();
      }

      final parsed = parseReceiptLines(lines, today: DateTime.now());
      if (!mounted) return;
      setState(() {
        _mode = _EntryMode.ocr;
        _editing = false;
        _date = parsed.date;
        _subtotal = parsed.subtotal;
        _gst = parsed.gst;
        _subtotalController.text = _subtotal?.toStringAsFixed(2) ?? '';
        _gstController.text = _gst?.toStringAsFixed(2) ?? '';
        _busy = false;
      });
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'addReceipt.ocrError', {'error': '$e'}))));
      }
    }
  }

  void _startManual() {
    setState(() {
      _mode = _EntryMode.manual;
      _editing = true;
      _date = null;
      _subtotal = null;
      _gst = null;
      _subtotalController.text = '';
      _gstController.text = '';
    });
  }

  Future<void> _pickDate() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: _date ?? DateTime.now(),
      firstDate: DateTime(2020),
      lastDate: DateTime(2100),
    );
    if (!mounted) return;
    if (picked != null) {
      setState(() {
        _date = picked;
        _dateError = null;
      });
    }
  }

  /// Section 8: Date, Subtotal and GST are required; Description is not.
  /// Populates the per-field error messages and, if the receipt is still in
  /// the un-edited OCR preview, switches it into edit mode so the user can
  /// actually fix the offending field(s) -- read-only fields can't be
  /// corrected otherwise.
  bool _validate() {
    final subtotal = _editing ? parseDecimal(_subtotalController.text) : _subtotal;
    final gst = _editing ? parseDecimal(_gstController.text) : _gst;

    final dateError = _date == null ? t(context, 'addReceipt.dateRequired') : null;
    final subtotalError = subtotal == null ? t(context, 'addReceipt.subtotalRequired') : null;
    final gstError = gst == null ? t(context, 'addReceipt.gstRequired') : null;
    final hasError = dateError != null || subtotalError != null || gstError != null;

    setState(() {
      _dateError = dateError;
      _subtotalError = subtotalError;
      _gstError = gstError;
      if (hasError) _editing = true;
    });
    return !hasError;
  }

  bool get _gstLooksOff {
    final subtotal = _editing ? parseDecimal(_subtotalController.text) : _subtotal;
    final gst = _editing ? parseDecimal(_gstController.text) : _gst;
    if (subtotal == null || gst == null || subtotal == 0) return false;
    // 0.05: the standard Canadian GST rate (5%) -- this warning exists to
    // catch a mis-scanned/mis-typed GST field, not to enforce provincial
    // tax law, so it's intentionally just the federal rate.
    final expected = subtotal * 0.05;
    if (expected == 0) return false;
    // Both numerator and denominator by modulus (section 8): a plain
    // signed division would flip sign on a return receipt (negative
    // Subtotal -> negative expected), silently disabling this check right
    // when it's needed most.
    final deviation = (gst - expected).abs() / expected.abs();
    // 0.15: 15% tolerance around the expected 5% -- wide enough to absorb
    // rounding on the receipt itself and OCR digit noise without going
    // silent on a genuinely wrong GST value (Пакет 39, audit 2026-08-18).
    return deviation > 0.15;
  }

  Future<void> _save() async {
    if (_busy) return; // guards against a second tap starting a concurrent write
    if (!_validate()) return;
    final subtotal = _editing ? parseDecimal(_subtotalController.text) : _subtotal;
    final gst = _editing ? parseDecimal(_gstController.text) : _gst;
    final description = sanitizeFreeText(_descriptionController.text);

    setState(() {
      _busy = true;
      _savePhase = SaveXlsxPhase.reading;
    });
    try {
      // Already resolved (and non-null -- the screen is gated on it in
      // build()) by the time Save is reachable; awaiting the same Future
      // again just returns the cached result, no re-resolve.
      final cycle = (await _cycleFuture)!;
      final fileManager = PeriodFileManager();
      final file = await fileManager.mileageReportFile(cycle);
      final settings = await SettingsRepository().load();
      final input = ReceiptInput(
        date: _date,
        description: description.isEmpty ? null : description,
        // Section 8: round to 2 decimals here, at the point the value
        // leaves the screen -- a typed "12.3456" must never reach the
        // file as anything but 12.35.
        subtotal: subtotal == null ? null : round2(subtotal),
        gst: gst == null ? null : round2(gst),
      );
      void onPhase(SaveXlsxPhase phase) {
        if (mounted) setState(() => _savePhase = phase);
      }

      final existing = widget.existing;
      if (existing != null) {
        // Section 14: editing writes back to the same row, no Kilometers-
        // row shift, so the rate parameters writeReceipt needs don't apply.
        await updateMileageReceipt(file, row: existing.row, receipt: input, onPhase: onPhase);
      } else {
        await saveMileageReceipt(
          file,
          input,
          // Section 6.2's priority rule: the CYCLE's own rate wins if set
          // (fixed on its opening half, not widget.period -- see
          // MileageCycle.kmRate), otherwise the Settings default -- and the
          // file's own G1 wins over both if it's already filled (resolved
          // inside the engine). Using widget.period.kmRate here would be
          // wrong for the second-half period, whose own kmRate field is no
          // longer meaningful for Mileage once a cycle is formed.
          periodKmRate: cycle.kmRate,
          settingsDefaultRate: settings.kmRate,
          onPhase: onPhase,
        );
      }

      if (mounted) Navigator.of(context).pop(true);
    } on MileageReportRowsExhaustedException {
      if (mounted) {
        setState(() => _busy = false);
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t(context, 'mileageReport.noRoomTitle')),
            content: Text(t(context, 'addReceipt.noRoomContent')),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t(context, 'common.ok'))),
            ],
          ),
        );
      }
    } catch (e) {
      if (mounted) {
        setState(() => _busy = false);
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'addReceipt.saveError', {'error': '$e'}))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        title: Text(t(context, widget.existing != null ? 'addReceipt.editTitle' : 'addReceipt.title')),
      ),
      body: FutureBuilder<MileageCycle?>(
        future: _cycleFuture,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          if (snapshot.data == null) {
            return Center(
              child: Padding(
                padding: const EdgeInsets.all(24),
                child: Text(t(context, 'mileageCycle.notReadyMessage'), textAlign: TextAlign.center),
              ),
            );
          }
          return _busy
              ? _buildSaveProgress(context)
              : _mode == _EntryMode.none
                  ? _buildEntryChoice()
                  : _buildConfirmForm();
        },
      ),
    );
  }

  Widget _buildSaveProgress(BuildContext context) {
    final label = saveXlsxPhaseLabel(context, _savePhase);
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const CircularProgressIndicator(),
          if (label != null) ...[
            const SizedBox(height: 16),
            Text(label),
          ],
        ],
      ),
    );
  }

  Widget _buildEntryChoice() {
    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Card(
          child: ListTile(
            leading: const Icon(Icons.camera_alt),
            title: Text(t(context, 'addReceipt.camera')),
            onTap: () => _pickAndScan(ImageSource.camera),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.photo_library),
            title: Text(t(context, 'addReceipt.gallery')),
            onTap: () => _pickAndScan(ImageSource.gallery),
          ),
        ),
        Card(
          child: ListTile(
            leading: const Icon(Icons.edit),
            title: Text(t(context, 'addReceipt.manual')),
            onTap: _startManual,
          ),
        ),
      ],
    );
  }

  Widget _buildConfirmForm() {
    final dateFmt = _date == null ? '—' : formatDate(_date!);

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          title: Text(t(context, 'addReceipt.date')),
          subtitle: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(dateFmt),
              if (_dateError != null) Text(_dateError!, style: const TextStyle(color: Colors.red)),
            ],
          ),
          trailing: _editing ? const Icon(Icons.calendar_today) : null,
          onTap: _editing ? _pickDate : null,
        ),
        const Divider(),
        if (_editing) ...[
          TextField(
            controller: _subtotalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t(context, 'addReceipt.subtotal'), errorText: _subtotalError),
            onChanged: (_) => setState(() => _subtotalError = null),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _gstController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t(context, 'addReceipt.gst'), errorText: _gstError),
            onChanged: (_) => setState(() => _gstError = null),
          ),
        ] else ...[
          ListTile(title: Text(t(context, 'addReceipt.subtotal')), subtitle: Text(_subtotal?.toStringAsFixed(2) ?? '—')),
          ListTile(title: Text(t(context, 'addReceipt.gst')), subtitle: Text(_gst?.toStringAsFixed(2) ?? '—')),
        ],
        if (_gstLooksOff)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              t(context, 'addReceipt.gstWarning'),
              style: const TextStyle(color: Colors.orange),
            ),
          ),
        const Divider(),
        TextField(
          controller: _descriptionController,
          decoration: InputDecoration(labelText: t(context, 'addReceipt.description')),
          maxLines: 2,
          maxLength: 300,
        ),
        const SizedBox(height: 24),
        if (_mode == _EntryMode.ocr && !_editing)
          OutlinedButton(
            onPressed: () => setState(() => _editing = true),
            child: Text(t(context, 'common.edit')),
          ),
        const SizedBox(height: 8),
        FilledButton(onPressed: _save, child: Text(t(context, 'common.save'))),
      ],
    );
  }
}
