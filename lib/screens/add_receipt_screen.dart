import 'dart:io';

import 'package:flutter/material.dart';
import 'package:google_mlkit_text_recognition/google_mlkit_text_recognition.dart';
import 'package:image_picker/image_picker.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/receipt_parser.dart';
import '../services/safe_xlsx_write.dart';
import '../xlsx/mileage_report_engine.dart';

enum _EntryMode { none, ocr, manual }

class AddReceiptScreen extends StatefulWidget {
  final PayrollPeriod period;

  const AddReceiptScreen({super.key, required this.period});

  @override
  State<AddReceiptScreen> createState() => _AddReceiptScreenState();
}

class _AddReceiptScreenState extends State<AddReceiptScreen> {
  _EntryMode _mode = _EntryMode.none;
  bool _editing = false;
  bool _busy = false;

  DateTime? _date;
  double? _subtotal;
  double? _gst;
  final _descriptionController = TextEditingController();
  final _subtotalController = TextEditingController();
  final _gstController = TextEditingController();

  @override
  void dispose() {
    _descriptionController.dispose();
    _subtotalController.dispose();
    _gstController.dispose();
    super.dispose();
  }

  Future<void> _pickAndScan(ImageSource source) async {
    setState(() => _busy = true);
    try {
      final picker = ImagePicker();
      final photo = await picker.pickImage(source: source, imageQuality: 85);
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
      setState(() => _busy = false);
      if (mounted) {
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
    if (picked != null) setState(() => _date = picked);
  }

  bool get _gstLooksOff {
    final subtotal = _editing ? double.tryParse(_subtotalController.text) : _subtotal;
    final gst = _editing ? double.tryParse(_gstController.text) : _gst;
    if (subtotal == null || gst == null || subtotal == 0) return false;
    final expected = subtotal * 0.05;
    if (expected == 0) return false;
    final deviation = (gst - expected).abs() / expected;
    return deviation > 0.15;
  }

  Future<void> _save() async {
    final subtotal = _editing ? double.tryParse(_subtotalController.text) : _subtotal;
    final gst = _editing ? double.tryParse(_gstController.text) : _gst;
    final description = _descriptionController.text.trim();

    setState(() => _busy = true);
    try {
      final fileManager = PeriodFileManager();
      final file = await fileManager.mileageReportFile(widget.period);
      final engine = MileageReportEngine.fromBytes(await file.readAsBytes());
      final kmTotal = engine.sumDrivingDetailsKm();

      engine.writeReceipt(
        ReceiptInput(
          date: _date,
          description: description.isEmpty ? null : description,
          subtotal: subtotal,
          gst: gst,
        ),
        currentKmTotal: kmTotal,
      );

      await writeMileageReportSafely(file, engine.save());

      if (mounted) Navigator.of(context).pop(true);
    } on MileageReportRowsExhaustedException {
      setState(() => _busy = false);
      if (mounted) {
        showDialog<void>(
          context: context,
          builder: (context) => AlertDialog(
            title: Text(t(context, 'addReceipt.noRoomTitle')),
            content: Text(t(context, 'addReceipt.noRoomContent')),
            actions: [
              TextButton(onPressed: () => Navigator.of(context).pop(), child: Text(t(context, 'common.ok'))),
            ],
          ),
        );
      }
    } catch (e) {
      setState(() => _busy = false);
      if (mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(t(context, 'addReceipt.saveError', {'error': '$e'}))));
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'addReceipt.title'))),
      body: _busy
          ? const Center(child: CircularProgressIndicator())
          : _mode == _EntryMode.none
              ? _buildEntryChoice()
              : _buildConfirmForm(),
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
    final dateFmt = _date == null
        ? '—'
        : '${_date!.year}-${_date!.month.toString().padLeft(2, '0')}-${_date!.day.toString().padLeft(2, '0')}';

    return ListView(
      padding: const EdgeInsets.all(16),
      children: [
        ListTile(
          title: Text(t(context, 'addReceipt.date')),
          subtitle: Text(dateFmt),
          trailing: _editing ? const Icon(Icons.calendar_today) : null,
          onTap: _editing ? _pickDate : null,
        ),
        const Divider(),
        if (_editing) ...[
          TextField(
            controller: _subtotalController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t(context, 'addReceipt.subtotal')),
            onChanged: (_) => setState(() {}),
          ),
          const SizedBox(height: 8),
          TextField(
            controller: _gstController,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(labelText: t(context, 'addReceipt.gst')),
            onChanged: (_) => setState(() {}),
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
