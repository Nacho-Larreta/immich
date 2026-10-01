import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/backup_callback_fence.dart';
import 'package:immich_mobile/domain/services/backup_enablement_controller.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/background_downloader_task_registry_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_enablement.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../domain/service.mock.dart';
import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

void main() {
  for (final startsWithActiveNativeTask in [false, true]) {
    test(
      'OFF drain recovers a persisted orphan after native task ${startsWithActiveNativeTask ? 'cancels' : 'is absent'}',
      () async {
        final directory = await Directory.systemTemp.createTemp('immich-backup-orphan-');
        final file = File('${directory.path}/shared.sqlite');
        final now = DateTime.utc(2026, 10, 1, 15);
        const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'orphaned-enqueue');
        const candidateKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
        final lease = BackupExecutionLease(
          mode: BackupExecutionMode.background,
          runToken: 'persisted-run',
          bindingDigest: 'binding-digest',
          expiresAt: now.subtract(const Duration(minutes: 1)),
          activityRevision: 3,
          callbacksInFlight: 0,
          state: BackupExecutionState.closing,
          enqueueClaims: {claim},
          candidateKeys: {claim: candidateKey},
          enqueueIncarnations: {claim: 'previous-process'},
        );
        final seedDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
        await seedDb.customSelect('SELECT 1').get();
        final seedEnablement = DriftBackupEnablementRepository(seedDb);
        await seedEnablement.initialize(true);
        await seedDb.customUpdate(
          'INSERT OR REPLACE INTO store_entity (id, string_value, int_value) VALUES (?1, ?2, NULL)',
          variables: [Variable.withInt(StoreKey.backupExecutionLease.id), Variable.withString(lease.toJson())],
          updates: {seedDb.storeEntity},
        );
        final disabling = await seedEnablement.beginDisable();
        expect(await seedEnablement.failDrain(disabling), isTrue);
        await seedDb.close();

        final recoveryDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
        await recoveryDb.customSelect('SELECT 1').get();
        final enablement = DriftBackupEnablementRepository(recoveryDb);
        final leases = DriftBackupExecutionLeaseRepository(recoveryDb);
        final native = _EmptyNativeRegistry();
        if (startsWithActiveNativeTask) {
          native.tasks = [
            UploadTask(
              taskId: claim.taskId,
              url: 'https://photos.example/api/assets',
              filename: 'asset.mov',
              group: kBackupGroup,
            ),
          ];
          native.allowCancel = false;
        }
        final uploads = UploadRepository(taskRegistry: native);
        final fence = BackupCallbackFence();
        final arbiter = BackupExecutionArbiter(
          leases: leases,
          tasks: uploads,
          callbackFence: fence,
          clock: () => now,
          tokenFactory: () => 'next-run',
        );
        final storage = _MockStorageRepository();
        when(() => storage.clearCache()).thenAnswer((_) async {});
        final service = BackgroundUploadService(
          uploads,
          storage,
          _MockLocalAssetRepository(),
          _MockBackupRepository(),
          _MockAppSettingsService(),
          _MockAssetMediaRepository(),
          leasePort: leases,
          arbiter: arbiter,
          callbackFence: fence,
          operationIncarnation: 'current-process',
        );
        final port = _PersistedEnablementPort(
          enablement,
          leases,
          arbiter,
          drainAction: () async => await service.cancel() == 0,
        );
        final controller = BackupEnablementController(port, initiallyEnabled: false);

        try {
          await controller.initialize(false);
          if (startsWithActiveNativeTask) {
            expect(controller.state, const BackupEnablementState.drainFailed());
            expect((await leases.read())?.enqueueClaims, {claim});
            expect(await controller.enable(), BackupEnablementResult.drainFailed);
            expect((await enablement.read())?.phase, DurableBackupEnablementPhase.drainFailed);
            native.allowCancel = true;
          } else {
            expect(controller.state, const BackupEnablementState.disabled());
            expect(await leases.read(), isNull);
          }
          expect(await leases.readReconciliationQuarantine(), isEmpty);

          expect(await controller.enable(), BackupEnablementResult.applied);
          expect((await enablement.read())?.phase, DurableBackupEnablementPhase.enabled);
          final admission = await arbiter.acquireForeground(bindingDigest: lease.bindingDigest);
          expect(admission.disposition, BackupAdmissionDisposition.acquired);
          expect(admission.lease?.runToken, 'next-run');
          const retryClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'retry-enqueue');
          final retry = await leases.reserveEnqueueForCandidate(
            runToken: admission.lease!.runToken,
            bindingDigest: admission.lease!.bindingDigest,
            claim: retryClaim,
            candidateKey: candidateKey,
            operationIncarnation: 'current-process',
          );
          expect(retry?.enqueueClaims, contains(retryClaim));
          expect(native.replayCalls, greaterThanOrEqualTo(1));
        } finally {
          await controller.dispose();
          service.dispose();
          await recoveryDb.close();
          await directory.delete(recursive: true);
        }
      },
    );
  }

  test('relaunch retires a persisted schema-7 session-A claim after session-B native proof and applies ON', () async {
    final directory = await Directory.systemTemp.createTemp('immich-backup-recovery-');
    final file = File('${directory.path}/shared.sqlite');
    final now = DateTime.utc(2026, 9, 2, 13);
    const callbackClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'persisted-callback');
    final build244Claim = ForegroundTransportClaim.current(
      activityId: 'persisted-foreground',
      bindingDigest: 'binding-digest',
      nativeGeneration: 7,
      transportIncarnation: 'session-a-process',
    );
    final build244Lease = BackupExecutionLease(
      mode: BackupExecutionMode.foreground,
      runToken: 'persisted-run',
      bindingDigest: 'binding-digest',
      expiresAt: now.subtract(const Duration(minutes: 1)),
      activityRevision: 9,
      callbacksInFlight: 1,
      state: BackupExecutionState.closing,
      outstandingClaims: {callbackClaim},
      callbackClaims: {callbackClaim},
      foregroundActivityClaims: {build244Claim},
    );
    final build244Payload = build244Lease.toJson();
    final build244Envelope = jsonDecode(build244Payload) as Map<String, dynamic>;
    final build244PersistedClaim =
        (build244Envelope['foregroundActivityClaims'] as List<dynamic>).single as Map<String, dynamic>;
    expect(build244PersistedClaim['claimSchemaVersion'], ForegroundTransportClaim.currentSchemaVersion);
    expect(build244PersistedClaim['transportIncarnation'], 'session-a-process');

    final build243Payload = _reserializeWithBuild243(build244Payload);
    expect(build243Payload, _build243DowngradedLeaseFixture);
    final staleLease = BackupExecutionLease.tryParse(build243Payload)!;
    final foregroundClaim = staleLease.foregroundActivityClaims.single;
    expect(foregroundClaim.isLegacy, isTrue);

    final seedDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await seedDb.customSelect('SELECT 1').get();
    final seedEnablement = DriftBackupEnablementRepository(seedDb);
    final seedLeases = DriftBackupExecutionLeaseRepository(seedDb);
    await seedEnablement.initialize(true);
    await seedDb.customUpdate(
      'INSERT OR REPLACE INTO store_entity (id, string_value, int_value) VALUES (?1, ?2, NULL)',
      variables: [Variable.withInt(StoreKey.backupExecutionLease.id), Variable.withString(build243Payload)],
      updates: {seedDb.storeEntity},
    );
    expect(await seedLeases.read(), staleLease);
    final rawLease = await seedDb
        .customSelect(
          'SELECT string_value FROM store_entity WHERE id = ?1',
          variables: [Variable.withInt(StoreKey.backupExecutionLease.id)],
        )
        .getSingle();
    final persisted = jsonDecode(rawLease.read<String>('string_value')) as Map<String, dynamic>;
    final persistedClaim = (persisted['foregroundActivityClaims'] as List<dynamic>).single as Map<String, dynamic>;
    expect(persisted['schemaVersion'], 7);
    expect(persistedClaim['transportIncarnation'], isNull);
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
      expect(await _readRawLease(recoveryDb), build243Payload);

      foregroundFence.retirement = ForegroundTransportRetirement.retired;
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

const _build243DowngradedLeaseFixture =
    '{"schemaVersion":7,"mode":"foreground","runToken":"persisted-run","bindingDigest":"binding-digest",'
    '"expiryEpochMs":1788353940000,"activityRevision":9,"callbacksInFlight":1,"state":"closing",'
    '"outstandingClaims":[{"group":"primary","taskId":"persisted-callback"}],"enqueueClaims":[],'
    '"terminalTombstones":[],"callbackClaims":[{"group":"primary","taskId":"persisted-callback"}],'
    '"reconciliationClaims":[],"candidateKeys":[],"foregroundActivityClaims":['
    '{"activityId":"persisted-foreground","bindingDigest":"binding-digest","nativeGeneration":7}]}';

String _reserializeWithBuild243(String source) {
  final envelope = jsonDecode(source) as Map<String, dynamic>;
  final claims = envelope['foregroundActivityClaims'] as List<dynamic>;
  envelope['foregroundActivityClaims'] = [
    for (final value in claims)
      {
        'activityId': (value as Map<String, dynamic>)['activityId'],
        'bindingDigest': value['bindingDigest'],
        'nativeGeneration': value['nativeGeneration'],
      },
  ];
  return jsonEncode(envelope);
}

Future<String?> _readRawLease(Drift db) async {
  final row = await db
      .customSelect(
        'SELECT string_value FROM store_entity WHERE id = ?1',
        variables: [Variable.withInt(StoreKey.backupExecutionLease.id)],
      )
      .getSingleOrNull();
  return row?.read<String?>('string_value');
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
  _PersistedEnablementPort(this._enablement, this._leases, this._arbiter, {this.drainAction});

  final DriftBackupEnablementRepository _enablement;
  final DriftBackupExecutionLeaseRepository _leases;
  final BackupExecutionArbiter _arbiter;
  final Future<bool> Function()? drainAction;
  int signalCount = 0;

  @override
  Future<bool> admitsBackupWork() => _enablement.admitsBackupWork();

  @override
  Future<DurableBackupEnablementState> beginDisable() => _enablement.beginDisable();

  @override
  Future<bool> completeDrain(DurableBackupEnablementState disabling) => _enablement.completeDrain(disabling);

  @override
  Future<bool> drain() async {
    if (drainAction case final action?) return action();
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

final class _EmptyNativeRegistry implements BackupTaskRegistryGateway {
  int replayCalls = 0;
  List<Task> tasks = [];
  bool allowCancel = true;

  @override
  Future<void> get ready async {}

  @override
  Future<List<Task>> nativeTasks(String group) async => tasks.where((task) => task.group == group).toList();

  @override
  Future<List<Task>> nativeTasksInGroups(Set<String> groups) async =>
      tasks.where((task) => groups.contains(task.group)).toList();

  @override
  Future<List<TaskRecord>> trackingRecords(TaskStatus status, String group) async => const [];

  @override
  Future<List<TaskRecord>> allTrackingRecords(String group) async => const [];

  @override
  Future<void> replayUndeliveredUpdates() async => replayCalls++;

  @override
  Future<bool> cancelNative(String group) async {
    if (!allowCancel) return false;
    tasks.removeWhere((task) => task.group == group);
    return true;
  }

  @override
  Future<void> resetNative(String group) async {}

  @override
  Future<void> deleteTrackingRecords(Iterable<String> taskIds) async {}

  @override
  Future<void> repairTracking(TaskRecord record) async {}
}

final class _MockStorageRepository extends MockStorageRepository {}

final class _MockLocalAssetRepository extends MockDriftLocalAssetRepository {}

final class _MockBackupRepository extends MockDriftBackupRepository {}

final class _MockAppSettingsService extends MockAppSettingsService {}

final class _MockAssetMediaRepository extends MockAssetMediaRepository {}

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
  ForegroundTransportRetirement retirement = ForegroundTransportRetirement.temporarilyUnproven;
  final List<ForegroundTransportClaim> claims = [];

  @override
  Future<ForegroundTransportIdentity?> captureIdentity() async =>
      const ForegroundTransportIdentity(incarnation: 'current-process', generation: 7);

  @override
  bool isIdentityCurrent(ForegroundTransportIdentity identity, {required String bindingDigest}) => true;

  @override
  Future<ForegroundTransportRetirement> retireClaims(
    Set<ForegroundTransportClaim> requestedClaims, {
    required Duration timeout,
  }) async {
    claims.addAll(requestedClaims);
    return retirement;
  }
}
