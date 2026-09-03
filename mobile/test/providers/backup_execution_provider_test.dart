import 'package:background_downloader/background_downloader.dart';
import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/background_downloader_task_registry_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_enablement.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/backup/backup_execution.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

void main() {
  test('root iOS provider exposes its shared same-isolate callback recovery capability', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
    final container = ProviderContainer();

    try {
      expect(
        container.read(backupCallbackRecoveryCapabilityProvider),
        same(container.read(backupCallbackFenceProvider)),
      );
    } finally {
      container.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('root Android provider exposes no process-local callback recovery capability', () {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
    final container = ProviderContainer();

    try {
      expect(container.read(backupCallbackRecoveryCapabilityProvider), isNull);
    } finally {
      container.dispose();
      debugDefaultTargetPlatformOverride = null;
    }
  });

  test('attached iOS worker provider fails closed instead of using its process-local callback fence', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    NetworkRepository.setContextRoleForTest(NetworkContextRole.attachedWorker);
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    final leases = DriftBackupExecutionLeaseRepository(db);
    final now = DateTime.now().toUtc();
    const callbackClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'live-primary-callback');
    final staleLease = BackupExecutionLease(
      mode: BackupExecutionMode.background,
      runToken: 'attached-worker-run',
      bindingDigest: 'binding-digest',
      expiresAt: now.subtract(const Duration(minutes: 1)),
      activityRevision: 4,
      callbacksInFlight: 1,
      state: BackupExecutionState.closing,
      outstandingClaims: {callbackClaim},
      callbackClaims: {callbackClaim},
    );
    await DriftBackupEnablementRepository(db).initialize(true);
    expect(await leases.acquire(staleLease, now), isTrue);
    final persistedLease = await leases.read();
    expect(persistedLease, isNotNull);
    final container = ProviderContainer(
      overrides: [
        driftProvider.overrideWithValue(db),
        uploadRepositoryProvider.overrideWithValue(UploadRepository(taskRegistry: const _EmptyGateway())),
        backupRunBindingSourceProvider.overrideWithValue(const _UnavailableBindingSource()),
      ],
    );

    try {
      final arbiter = container.read(backupExecutionArbiterProvider);

      expect(
        await arbiter.disableAndDrain(runToken: staleLease.runToken, bindingDigest: staleLease.bindingDigest),
        isFalse,
      );
      expect(await leases.read(), persistedLease);
    } finally {
      container.dispose();
      NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
      debugDefaultTargetPlatformOverride = null;
      await db.close();
    }
  });
}

final class _UnavailableBindingSource implements BackupRunBindingSourcePort {
  const _UnavailableBindingSource();

  @override
  BackupRunBinding? capture() => null;

  @override
  bool isCurrent(BackupRunBinding binding) => false;
}

final class _EmptyGateway implements BackupTaskRegistryGateway {
  const _EmptyGateway();

  @override
  Future<void> get ready async {}

  @override
  Future<List<TaskRecord>> allTrackingRecords(String group) async => const [];

  @override
  Future<bool> cancelNative(String group) async => true;

  @override
  Future<void> deleteTrackingRecords(Iterable<String> taskIds) async {}

  @override
  Future<List<Task>> nativeTasks(String group) async => const [];

  @override
  Future<List<Task>> nativeTasksInGroups(Set<String> groups) async => const [];

  @override
  Future<void> repairTracking(TaskRecord record) async {}

  @override
  Future<void> replayUndeliveredUpdates() async {}

  @override
  Future<void> resetNative(String group) async {}

  @override
  Future<List<TaskRecord>> trackingRecords(TaskStatus status, String group) async => const [];
}
