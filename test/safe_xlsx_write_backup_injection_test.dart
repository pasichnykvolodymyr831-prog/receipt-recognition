// Пакет 33 (audit 2026-08-18): the write functions in safe_xlsx_write.dart
// used to always call a fixed module-level BackupManager instance with no
// way to substitute a fake for tests -- unlike PeriodFileManager, which
// already accepts an optional BackupManager via its constructor for
// exactly this reason. This proves the newly-added optional `backupManager`
// parameter is actually honored, not just accepted and ignored.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/services/backup_manager.dart';
import 'package:expenseflow/services/safe_xlsx_write.dart';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

class _SpyBackupManager extends BackupManager {
  bool called = false;

  @override
  Future<void> backupBeforeWrite(File targetFile) async {
    called = true;
    await super.backupBeforeWrite(targetFile);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() async {
    final docsDir = await Directory.systemTemp.createTemp('backup_injection_test_docs');
    PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
  });

  test('saveMileageDrivingDetail uses the injected BackupManager, not the module default', () async {
    final dir = await Directory.systemTemp.createTemp('backup_injection_test');
    final file = File('${dir.path}/MileageReport_test.xlsx');
    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );

    final spy = _SpyBackupManager();
    await saveMileageDrivingDetail(
      file,
      date: DateTime(2026, 8, 10),
      trip: 'Injected-backup-manager check',
      km: 1.0,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
      backupManager: spy,
    );

    expect(spy.called, true, reason: 'the injected BackupManager must be the one actually used for this write');

    await dir.delete(recursive: true);
  });

  test('omitting backupManager still works (falls back to the module default)', () async {
    final dir = await Directory.systemTemp.createTemp('backup_injection_test_default');
    final file = File('${dir.path}/MileageReport_test.xlsx');
    await createMileagePeriod(
      file,
      periodLabel: 'Aug 9 - Aug 23, 2026',
      employeeName: 'Truman Homes',
      periodEnd: DateTime(2026, 8, 23),
      kmRate: 0.56,
    );

    // No backupManager passed -- must not throw, must behave exactly as
    // before this packet.
    await saveMileageDrivingDetail(
      file,
      date: DateTime(2026, 8, 10),
      trip: 'Default backup manager check',
      km: 1.0,
      periodKmRate: null,
      settingsDefaultRate: 0.56,
    );

    expect(await file.exists(), true);

    await dir.delete(recursive: true);
  });
}
