// Section 13.5: a pre-write backup must be taken before every write, and a
// corrupted file (app killed mid-write) must be recovered from that backup
// at next launch. Uses BackupManager's static File-based methods so it runs
// without path_provider platform channels.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:path_provider_platform_interface/path_provider_platform_interface.dart';

import 'package:expenseflow/services/backup_manager.dart';

const mileageTemplatePath = 'assets/templates/Truman_Homes_Mileage_Report_TEMPLATE.xlsx';

class _FakePathProviderPlatform extends PathProviderPlatform {
  _FakePathProviderPlatform(this._docsPath);
  final String _docsPath;

  @override
  Future<String?> getApplicationDocumentsPath() async => _docsPath;
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

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

  // Пакет 21 (audit 2026-08-18): backupBeforeWriteTo used to write the
  // backup slot directly (no tmp+rename), the one write in the whole
  // pipeline not following the atomic-replace pattern _atomicWrite already
  // uses for the primary period file (section 13, step 8).
  test('backupBeforeWriteTo leaves no leftover .tmp file after a successful write', () async {
    final target = File('${tempDir.path}/MileageReport_test.xlsx');
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    await target.writeAsBytes(File(mileageTemplatePath).readAsBytesSync());

    await BackupManager.backupBeforeWriteTo(target, backup);

    expect(await File('${backup.path}.tmp').exists(), false);
  });

  test('an abandoned .bak.tmp file (crash before rename) never corrupts an existing backup', () async {
    final backup = File('${tempDir.path}/MileageReport_test.xlsx.bak');
    final goodBackupBytes = File(mileageTemplatePath).readAsBytesSync();
    await backup.writeAsBytes(goodBackupBytes);

    // Simulate a crash between "write the new bytes to <backup>.tmp" and
    // "rename <backup>.tmp over <backup>": the real backup must stay intact.
    await File('${backup.path}.tmp').writeAsBytes([1, 2, 3, 4, 5]);

    expect(await backup.readAsBytes(), goodBackupBytes);
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

  // Fix for the Settings-exit freeze (sequential-gliding-clover.md): the
  // instance-level restoreIfCorrupted wraps restoreIfCorruptedUsing (tested
  // above) with a per-instance skip cache -- the full decode-based check
  // only needs to run once per file per app process lifetime (section 13.5
  // is about recovering a PREVIOUS session's kill-mid-write; this app's own
  // writes are already atomic, so nothing can corrupt a file between two
  // checks in the same continuous run).
  group('restoreIfCorrupted (instance, session-scoped skip cache)', () {
    late Directory docsDir;
    late Directory targetDir;

    setUp(() {
      docsDir = Directory.systemTemp.createTempSync('backup_manager_instance_docs');
      targetDir = Directory.systemTemp.createTempSync('backup_manager_instance_target');
      PathProviderPlatform.instance = _FakePathProviderPlatform(docsDir.path);
    });

    tearDown(() {
      docsDir.deleteSync(recursive: true);
      targetDir.deleteSync(recursive: true);
    });

    test('first call on a corrupted file restores it from backup (cache does not break the existing guarantee)',
        () async {
      final manager = BackupManager();
      final target = File('${targetDir.path}/MileageReport_test.xlsx');
      final validBytes = File(mileageTemplatePath).readAsBytesSync();
      await target.writeAsBytes([1, 2, 3, 4, 5]); // corrupted
      final backup = await manager.backupFileFor(target);
      await backup.create(recursive: true);
      await backup.writeAsBytes(validBytes);

      await manager.restoreIfCorrupted(target);

      expect(await target.readAsBytes(), validBytes);
    });

    test('second call on the SAME instance skips the check even if the file is corrupted again afterward',
        () async {
      final manager = BackupManager();
      final target = File('${targetDir.path}/MileageReport_test.xlsx');
      final validBytes = File(mileageTemplatePath).readAsBytesSync();
      await target.writeAsBytes(validBytes); // valid the first time
      final backup = await manager.backupFileFor(target);
      await backup.create(recursive: true);
      await backup.writeAsBytes(validBytes);

      await manager.restoreIfCorrupted(target); // first call: validates, caches

      // Corrupt the file AFTER the first check -- a real re-check would catch
      // this, but the whole point of the session cache is that it doesn't.
      await target.writeAsBytes([9, 9, 9]);
      await manager.restoreIfCorrupted(target); // second call: must be skipped

      expect(await target.readAsBytes(), [9, 9, 9]);
    });

    test('a NEW instance (simulating a fresh app process) re-validates, proving the cache does not leak',
        () async {
      final target = File('${targetDir.path}/MileageReport_test.xlsx');
      final validBytes = File(mileageTemplatePath).readAsBytesSync();
      await target.writeAsBytes(validBytes);
      final firstManager = BackupManager();
      final backup = await firstManager.backupFileFor(target);
      await backup.create(recursive: true);
      await backup.writeAsBytes(validBytes);
      await firstManager.restoreIfCorrupted(target); // validates & caches on firstManager

      await target.writeAsBytes([9, 9, 9]); // corrupt after that

      final freshManager = BackupManager(); // a new process would construct a new instance
      await freshManager.restoreIfCorrupted(target);

      expect(await target.readAsBytes(), validBytes);
    });
  });
}
