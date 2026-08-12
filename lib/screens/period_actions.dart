import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import 'add_receipt_screen.dart';
import 'driving_details_screen.dart';
import 'share_save_screen.dart';
import 'timesheet_screen.dart';

/// The Add receipt / Driving Details / Timesheet / Share-Save action tiles,
/// shared between the Home screen (current period) and the period archive
/// (section 14: past periods use the exact same screens).
class PeriodActionTiles extends StatelessWidget {
  final PayrollPeriod period;
  final VoidCallback? onChanged;

  const PeriodActionTiles({super.key, required this.period, this.onChanged});

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _ActionTile(
          icon: Icons.receipt_long,
          label: t(context, 'home.addReceipt'),
          onTap: () async {
            final saved = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (context) => AddReceiptScreen(period: period)),
            );
            if (saved == true) onChanged?.call();
          },
        ),
        _ActionTile(
          icon: Icons.directions_car,
          label: t(context, 'home.drivingDetails'),
          onTap: () async {
            final saved = await Navigator.of(context).push<bool>(
              MaterialPageRoute(builder: (context) => DrivingDetailsScreen(period: period)),
            );
            if (saved == true) onChanged?.call();
          },
        ),
        _ActionTile(
          icon: Icons.schedule,
          label: t(context, 'home.timesheet'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => TimesheetScreen(period: period)),
            );
          },
        ),
        _ActionTile(
          icon: Icons.ios_share,
          label: t(context, 'home.shareSave'),
          onTap: () {
            Navigator.of(context).push(
              MaterialPageRoute(builder: (context) => ShareSaveScreen(period: period)),
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

  const _ActionTile({required this.icon, required this.label, required this.onTap});

  @override
  Widget build(BuildContext context) {
    return Card(
      child: ListTile(
        leading: Icon(icon),
        title: Text(label),
        trailing: const Icon(Icons.chevron_right),
        onTap: onTap,
      ),
    );
  }
}
