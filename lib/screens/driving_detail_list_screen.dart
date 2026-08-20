import 'package:flutter/material.dart';

import '../l10n/app_strings.dart';
import '../models/payroll_period.dart';
import '../services/period_file_manager.dart';
import '../services/period_repository.dart';
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
      appBar: AppBar(title: Text(t(context, 'tripList.title'))),
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
