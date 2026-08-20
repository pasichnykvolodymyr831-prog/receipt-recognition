import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/safe_xlsx_write.dart';
import '../utils/time_format.dart';
import 'driving_details_screen.dart';

/// Lists already-saved Driving Details trips for [period] (section 14).
/// Tapping one opens [DrivingDetailsScreen] prefilled for editing; the list
/// is always re-read from the file on open, never cached.
class DrivingDetailListScreen extends StatefulWidget {
  final PayrollPeriod period;

  const DrivingDetailListScreen({super.key, required this.period});

  @override
  State<DrivingDetailListScreen> createState() => _DrivingDetailListScreenState();
}

class _DrivingDetailListScreenState extends State<DrivingDetailListScreen> {
  late Future<MileageReportSummary> _future;

  @override
  void initState() {
    super.initState();
    _future = _load();
  }

  Future<MileageReportSummary> _load() async {
    final file = await PeriodFileManager().mileageReportFile(widget.period);
    return readMileageReportSummary(file);
  }

  void _reload() => setState(() => _future = _load());

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(t(context, 'tripList.title'))),
      body: FutureBuilder<MileageReportSummary>(
        future: _future,
        builder: (context, snapshot) {
          if (snapshot.connectionState != ConnectionState.done) {
            return const Center(child: CircularProgressIndicator());
          }
          if (snapshot.hasError) {
            return Center(child: Text('${t(context, 'home.errorPrefix')} ${snapshot.error}'));
          }
          final trips = snapshot.data!.drivingDetails;
          if (trips.isEmpty) {
            return Center(child: Text(t(context, 'tripList.empty')));
          }
          return ListView.builder(
            itemCount: trips.length,
            itemBuilder: (context, index) {
              final trip = trips[index];
              return ListTile(
                title: Text(trip.trip),
                subtitle: Text(trip.date != null ? formatDate(trip.date!) : '—'),
                trailing: Text(trip.km != null ? trip.km!.toStringAsFixed(2) : '—'),
                onTap: () async {
                  final saved = await Navigator.of(context).push<bool>(
                    MaterialPageRoute(
                      builder: (context) => DrivingDetailsScreen(period: widget.period, existing: trip),
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
