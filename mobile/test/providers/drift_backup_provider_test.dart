import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  test('stale binding immediately after background acquire releases the durable lease', () async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    final leases = DriftBackupExecutionLeaseRepository(db);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
    final backgroundUploads = _MockBackgroundUploadService();
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      backgroundUploads,
      UploadSpeedManager(),
      arbiter,
      _StaleBindingSource(_binding()),
    );
    addTearDown(notifier.dispose);

    await notifier.startBackupWithURLSession('user-a');

    expect(await leases.read(), isNull);
  });
}

BackupRunBinding _binding() => BackupRunBinding(
  userId: 'user-a',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: 3,
  apiEndpoint: Uri.parse('https://photos.example/api'),
  canonicalOrigin: Uri.parse('https://photos.example'),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportRevision: 4,
  localLeaseRevision: 5,
);

final class _StaleBindingSource implements BackupRunBindingSourcePort {
  const _StaleBindingSource(this.binding);

  final BackupRunBinding binding;

  @override
  BackupRunBinding? capture() => binding;

  @override
  bool isCurrent(BackupRunBinding binding) => false;
}

final class _EmptyRegistry implements BackupTaskRegistryPort {
  const _EmptyRegistry();

  @override
  Future<void> get ready async {}

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async => const [];

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) async => true;
}

class _MockForegroundUploadService extends Mock implements ForegroundUploadService {}

class _MockBackgroundUploadService extends Mock implements BackgroundUploadService {}
