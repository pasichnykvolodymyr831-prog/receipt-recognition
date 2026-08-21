import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import 'add_receipt_screen.dart';
import 'driving_detail_list_screen.dart';
import 'driving_details_screen.dart';
import 'receipt_list_screen.dart';
import 'share_save_screen.dart';
import 'timesheet_screen.dart';

/// The Add receipt / Driving Details / Timesheet / Share-Save action tiles,
/// shared between the Home screen (current period) and the period archive.
///
/// Deliberate deviation from section 14 of the spec: the spec documents
/// adding new receipts/trips to an archived period as an intended scenario
/// ("a receipt turns up after the period closed"), but the user explicitly
/// asked to remove that ability from the archive (2026-08-19) -- so
/// [allowAdding] hides the two add-new tiles entirely there, while viewing/
/// editing already-saved ones (Receipts/Trips lists, Timesheet, Share/Save)
/// stays available.
class PeriodActionTiles extends StatelessWidget {
  final PayrollPeriod period;
  final VoidCallback? onChanged;

  /// Section 12/14: whether [period]'s files are actually present on disk
  /// (an archived period the retention window has since cleaned up won't
  /// have them). When false, every rendered tile is shown but disabled,
  /// with an explanation instead of doing nothing on tap or being hidden
  /// entirely (Пакет 10) -- the caller computes this via
  /// [PeriodFileManager.filesExist] once and passes it in, since checking
  /// it here per-tile would mean six redundant file-existence reads.
  final bool filesExist;

  /// Whether "Add receipt" and "Driving Details" (add-new-entry tiles) are
  /// shown at all -- true for the current period, false for the archive.
  final bool allowAdding;

  const PeriodActionTiles({
    super.key,
    required this.period,
    this.onChanged,
    required this.filesExist,
    required this.allowAdding,
  });

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        if (allowAdding)
          _ActionTile(
            icon: Icons.receipt_long,
            label: t(context, 'home.addReceipt'),
            enabled: filesExist,
            onTap: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (context) => AddReceiptScreen(period: period)),
              );
              if (saved == true) onChanged?.call();
            },
          ),
        _ActionTile(
          icon: Icons.receipt,
          label: t(context, 'home.receiptList'),
          enabled: filesExist,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => ReceiptListScreen(period: period)),
            );
          },
        ),
        if (allowAdding)
          _ActionTile(
            icon: Icons.directions_car,
            label: t(context, 'home.drivingDetails'),
            enabled: filesExist,
            onTap: () async {
              final saved = await Navigator.of(context).push<bool>(
                MaterialPageRoute(builder: (context) => DrivingDetailsScreen(period: period)),
              );
              if (saved == true) onChanged?.call();
            },
          ),
        _ActionTile(
          icon: Icons.list_alt,
          label: t(context, 'home.tripList'),
          enabled: filesExist,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => DrivingDetailListScreen(period: period)),
            );
          },
        ),
        _ActionTile(
          icon: Icons.schedule,
          label: t(context, 'home.timesheet'),
          enabled: filesExist,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => TimesheetScreen(period: period)),
            );
          },
        ),
        _ActionTile(
          icon: Icons.ios_share,
          label: t(context, 'home.shareSave'),
          enabled: filesExist,
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => ShareSaveScreen.forPeriod(period: period)),
            );
          },
        ),
      ],
    );
  }
}

class _ActionTile extends StatelessWidget {
  final IconData icon;
  final String label;
  final VoidCallback onTap;
  final bool enabled;

  const _ActionTile({required this.icon, required this.label, required this.onTap, required this.enabled});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        subtitle: enabled ? null : Text(t(context, 'periodActions.filesUnavailable')),
        trailing: const Icon(Icons.chevron_right),
        onTap: enabled ? onTap : null,
      ),
    );
  }
}
