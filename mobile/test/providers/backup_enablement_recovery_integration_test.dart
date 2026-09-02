import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_callback_fence.dart';
import 'package:immich_mobile/domain/services/backup_enablement_controller.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_enablement.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

void main() {
  test('recreated controller recovers persisted drain failure before applying ON', () async {
    final directory = await Directory.systemTemp.createTemp('immich-backup-recovery-');
    final file = File('${directory.path}/shared.sqlite');
    final now = DateTime.utc(2026, 9, 2, 13);
    const callbackClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'persisted-callback');
    const foregroundClaim = ForegroundTransportClaim(
      activityId: 'persisted-foreground',
      bindingDigest: 'binding-digest',
      nativeGeneration: 7,
    );
    final staleLease = BackupExecutionLease(
      mode: BackupExecutionMode.foreground,
      runToken: 'persisted-run',
      bindingDigest: 'binding-digest',
      expiresAt: now.subtract(const Duration(minutes: 1)),
      activityRevision: 9,
      callbacksInFlight: 1,
      state: BackupExecutionState.closing,
      outstandingClaims: {callbackClaim},
      callbackClaims: {callbackClaim},
      foregroundActivityClaims: {foregroundClaim},
    );

    final seedDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await seedDb.customSelect('SELECT 1').get();
    final seedEnablement = DriftBackupEnablementRepository(seedDb);
    final seedLeases = DriftBackupExecutionLeaseRepository(seedDb);
    await seedEnablement.initialize(true);
    expect(await seedLeases.acquire(staleLease, now), isTrue);
    final disabling = await seedEnablement.beginDisable();
    expect(await seedEnablement.failDrain(disabling), isTrue);
    await seedDb.close();

    final recoveryDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await recoveryDb.customSelect('SELECT 1').get();
    final enablement = DriftBackupEnablementRepository(recoveryDb);
    final leases = DriftBackupExecutionLeaseRepository(recoveryDb);
    final foregroundFence = _ForegroundFence();
    final tasks = _EmptyTaskRegistry();
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: tasks,
      foregroundFence: foregroundFence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );
    final port = _PersistedEnablementPort(enablement, leases, arbiter);
    final controller = BackupEnablementController(port, initiallyEnabled: false);

    try {
      await controller.initialize(false);
      expect(controller.state, const BackupEnablementState.drainFailed());
      expect((await enablement.read())?.phase, DurableBackupEnablementPhase.drainFailed);
      expect(await leases.read(), staleLease);

      foregroundFence.acknowledged = true;
      expect(await controller.enable(), BackupEnablementResult.applied);

      expect(controller.state, const BackupEnablementState.enabled());
      expect((await enablement.read())?.phase, DurableBackupEnablementPhase.enabled);
      expect(await _readLegacyEnabled(recoveryDb), isTrue);
      expect(await leases.read(), isNull);
      expect(tasks.snapshotCalls, 6);
      expect(foregroundFence.claims, [foregroundClaim, foregroundClaim]);
      expect(port.signalCount, 1);
    } finally {
      await controller.dispose();
      await recoveryDb.close();
      await directory.delete(recursive: true);
    }
  });
}

Future<bool> _readLegacyEnabled(Drift db) async {
  final row = await db
      .customSelect(
        'SELECT int_value FROM store_entity WHERE id = ?1',
        variables: [Variable.withInt(StoreKey.enableBackup.id)],
      )
      .getSingleOrNull();
  return row?.read<int?>('int_value') == 1;
}

final class _PersistedEnablementPort implements BackupEnablementPort {
  _PersistedEnablementPort(this._enablement, this._leases, this._arbiter);

  final DriftBackupEnablementRepository _enablement;
  final DriftBackupExecutionLeaseRepository _leases;
  final BackupExecutionArbiter _arbiter;
  int signalCount = 0;

  @override
  Future<bool> admitsBackupWork() => _enablement.admitsBackupWork();

  @override
  Future<DurableBackupEnablementState> beginDisable() => _enablement.beginDisable();

  @override
  Future<bool> completeDrain(DurableBackupEnablementState disabling) => _enablement.completeDrain(disabling);

  @override
  Future<bool> drain() async {
    final lease = await _leases.read();
    if (lease == null) return true;
    return _arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
  }

  @override
  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained) {
    return _enablement.enableFromDrained(disabledDrained);
  }

  @override
  Future<bool> failDrain(DurableBackupEnablementState disabling) => _enablement.failDrain(disabling);

  @override
  Future<DurableBackupEnablementState> initialize(bool legacyEnabled) => _enablement.initialize(legacyEnabled);

  @override
  void reportDrainFailed() {}

  @override
  void signalSettingChanged() => signalCount++;

  @override
  void stopEager() {}
}

final class _EmptyTaskRegistry implements BackupTaskRegistryPort {
  int snapshotCalls = 0;

  @override
  Future<void> get ready async {}

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) async => true;

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async {
    snapshotCalls++;
    return const [];
  }
}

final class _ForegroundFence implements ForegroundTransportFencePort {
  bool acknowledged = false;
  final List<ForegroundTransportClaim> claims = [];

  @override
  Future<bool> fenceAndDrain(ForegroundTransportClaim claim) async {
    claims.add(claim);
    return acknowledged;
  }
}
