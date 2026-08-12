// Section 13.5: a pre-write backup must be taken before every write, and a
// corrupted file (app killed mid-write) must be recovered from that backup
// at next launch. Uses BackupManager's static File-based methods so it runs
// without path_provider platform channels.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

import 'package:expenseflow/services/backup_manager.dart';

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';

void main() {
  late Directory tempDir;

  setUp(() {
    tempDir = Directory.systemTemp.createTempSync('backup_manager_test');
  });

  tearDown(() {
    tempDir.deleteSync(recursive: true);
  });

  test('backupBeforeWriteTo copies current content into the backup slot', () async {
    final target = File('${tempDir.path}/MileageReport_test.xlsx');
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    final originalBytes = File(mileageTemplatePath).readAsBytesSync();
    await target.writeAsBytes(originalBytes);

    await BackupManager.backupBeforeWriteTo(target, backup);

    expect(await backup.exists(), true);
    expect(await backup.readAsBytes(), originalBytes);
  });

  test('backupBeforeWriteTo is a no-op when the target does not exist yet', () async {
    final target = File('${tempDir.path}/does_not_exist.xlsx');
    final backup = File('${tempDir.path}/does_not_exist.xlsx.bak');

    await BackupManager.backupBeforeWriteTo(target, backup);

    expect(await backup.exists(), false);
  });

  test('restoreIfCorruptedUsing recovers a corrupted file from its backup', () async {
    final target = File('${tempDir.path}/MileageReport_test.xlsx');
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    final validBytes = File(mileageTemplatePath).readAsBytesSync();

    await backup.writeAsBytes(validBytes);
    // Simulate a write that was interrupted mid-flush (truncated/garbage file).
    await target.writeAsBytes([1, 2, 3, 4, 5]);

    await BackupManager.restoreIfCorruptedUsing(target, backup);

    expect(await target.readAsBytes(), validBytes);
  });

  test('restoreIfCorruptedUsing recreates a missing file from its backup', () async {
    final target = File('${tempDir.path}/MileageReport_test.xlsx');
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    final validBytes = File(mileageTemplatePath).readAsBytesSync();
    await backup.writeAsBytes(validBytes);

    await BackupManager.restoreIfCorruptedUsing(target, backup);

    expect(await target.exists(), true);
    expect(await target.readAsBytes(), validBytes);
  });

  test('restoreIfCorruptedUsing leaves a valid file untouched', () async {
    final target = File('${tempDir.path}/MileageReport_test.xlsx');
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    final validBytes = File(mileageTemplatePath).readAsBytesSync();
    await target.writeAsBytes(validBytes);
    // A stale/older backup that must NOT overwrite the still-valid current file.
    await backup.writeAsBytes([9, 9, 9]);

    await BackupManager.restoreIfCorruptedUsing(target, backup);

    expect(await target.readAsBytes(), validBytes);
  });

  test('restoreIfCorruptedUsing leaves a corrupted file alone if no backup exists', () async {
    final target = File('${tempDir.path}/MileageReport_test.xlsx');
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    await target.writeAsBytes([1, 2, 3]);

    await BackupManager.restoreIfCorruptedUsing(target, backup);

    expect(await target.readAsBytes(), [1, 2, 3]);
  });
}
