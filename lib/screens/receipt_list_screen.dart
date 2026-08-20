import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
import '../services/safe_xlsx_write.dart';
import '../utils/time_format.dart';
import 'add_receipt_screen.dart';

/// Lists already-saved receipts for [period] (section 14). Tapping one
/// opens [AddReceiptScreen] prefilled for editing; the list is always
/// re-read from the file on open, never cached.
class ReceiptListScreen extends StatefulWidget {
  final PayrollPeriod period;

  const ReceiptListScreen({super.key, required this.period});

  @override
  State<ReceiptListScreen> createState() => _ReceiptListScreenState();
}

class _ReceiptListScreenState extends State<ReceiptListScreen> {
  late Future<MileageReportSummary?> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  /// `null` means [widget.period] isn't paired into a Mileage cycle yet
  /// (see `MileageCycle`) -- no Mileage Report file could exist for it, not
  /// an error to surface via `snapshot.hasError`.
  Future<MileageReportSummary?> _load() async {
    final periodRepo = PeriodRepository();
    final periods = await periodRepo.loadAll();
    final cycle = periodRepo.mileageCycleFor(widget.period, periods);
    if (cycle == null) return null;
    final file = await PeriodFileManager().mileageReportFile(cycle);
    return readMileageReportSummary(file);
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'receiptList.title'))),
      body: FutureBuilder<MileageReportSummary?>(
        future: _future,
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
          final receipts = snapshot.data!.receipts;
          if (receipts.isEmpty) {
            return Center(child: Text(t(context, 'receiptList.empty')));
          }
          return ListView.builder(
            itemCount: receipts.length,
            itemBuilder: (context, index) {
              final receipt = receipts[index];
              final description = receipt.description;
              return ListTile(
                title: Text(description != null && description.isNotEmpty
                    ? description
                    : t(context, 'receiptList.noDescription')),
                subtitle: Text(receipt.date != null ? formatDate(receipt.date!) : '—'),
                trailing: Text(receipt.subtotal != null ? receipt.subtotal!.toStringAsFixed(2) : '—'),
                onTap: () async {
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (context) => AddReceiptScreen(period: widget.period, existing: receipt),
                    ),
                  );
                  if (saved == true) _reload();
                },
              );
            },
          );
        },
      ),
    );
  }
}
