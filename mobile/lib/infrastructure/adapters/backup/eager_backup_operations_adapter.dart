import 'dart:async';

import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';

final class EagerBackupOperationsAdapter implements EagerBackupOperationsPort {
  const EagerBackupOperationsAdapter({
    required String? Function() readUserId,
    required DriftBackupRepository backups,
    required BackgroundSyncManager synchronization,
    required ForegroundUploadService uploads,
    required BackupExecutionArbiter arbiter,
    required BackupRunBindingSourcePort bindings,
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) : _readUserId = readUserId,
       _backups = backups,
       _synchronization = synchronization,
       _uploads = uploads,
       _arbiter = arbiter,
       _bindings = bindings,
       _heartbeatInterval = heartbeatInterval;

  final String? Function() _readUserId;
  final DriftBackupRepository _backups;
  final BackgroundSyncManager _synchronization;
  final ForegroundUploadService _uploads;
  final BackupExecutionArbiter _arbiter;
  final BackupRunBindingSourcePort _bindings;
  final Duration _heartbeatInterval;

  @override
  Future<BackupWorkload> readWorkload() async {
    final userId = _readUserId();
    if (userId == null) return const BackupWorkload(total: 0, remainder: 0, processing: 0);
    final counts = await _backups.getAllCounts(userId);
    return BackupWorkload(total: counts.total, remainder: counts.remainder, processing: counts.processing);
  }

  @override
  Future<void> synchronizeLocal(EagerBackupCancellation cancellation) async {
    cancellation.onCancel(() => unawaited(_synchronization.cancelLocal()));
    await _synchronization.syncLocal();
  }

  @override
  Future<void> hashAssets(EagerBackupCancellation cancellation) async {
    cancellation.onCancel(() => unawaited(_synchronization.cancelLocal()));
    await _synchronization.hashAssets();
  }

  @override
  Future<BackupRunBinding?> captureBinding() async => _bindings.capture();

  @override
  Future<void> upload(BackupRunBinding binding, EagerBackupCancellation cancellation) async {
    final admission = await _arbiter.acquireForeground(bindingDigest: binding.digest);
    final lease = admission.lease;
    if (!admission.admitted || lease == null) {
      throw const EagerBackupFailure.staleContext();
    }

    final cancelToken = Completer<void>();
    cancellation.onCancel(() {
      if (!cancelToken.isCompleted) cancelToken.complete();
    });
    var failed = false;
    var permitAlive = true;
    ForegroundTransportClaim? activityClaim;
    Timer? heartbeat;
    Future<void>? renewalInFlight;
    Future<bool>? failedPermitDrain;
    bool isPermitCurrent() => permitAlive && !cancellation.isCancelled && _bindings.isCurrent(binding);

    try {
      activityClaim = await _arbiter.beginForegroundActivity(lease, nativeGeneration: binding.nativeGeneration);
      if (activityClaim == null) throw const EagerBackupFailure.staleContext();
      heartbeat = Timer.periodic(_heartbeatInterval, (_) {
        if (renewalInFlight != null || !permitAlive) return;
        late final Future<void> renewal;
        renewal = () async {
          try {
            final renewed = await _arbiter.renewCurrent(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
            if (renewed != null) return;
          } on Object {
            // Renewal failure is handled identically to an exact CAS miss.
          } finally {
            if (identical(renewalInFlight, renewal)) renewalInFlight = null;
          }
          permitAlive = false;
          if (!cancelToken.isCompleted) cancelToken.complete();
          failedPermitDrain ??= _arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
        }();
        renewalInFlight = renewal;
      });
      if (!isPermitCurrent()) throw const EagerBackupFailure.staleContext();
      await _uploads.uploadCandidates(
        binding.userId,
        cancelToken,
        binding: binding,
        executionLease: lease,
        isBindingCurrent: (_) => isPermitCurrent(),
        callbacks: UploadCallbacks(onError: (_, _) => failed = true),
      );
      if (!isPermitCurrent()) throw const EagerBackupFailure.staleContext();
      if (failed) throw const EagerBackupFailure.transient();
      if (!await _synchronization.syncRemoteForBinding(binding)) throw const EagerBackupFailure.transient();
      if (!isPermitCurrent()) throw const EagerBackupFailure.staleContext();
    } on EagerBackupFailure {
      rethrow;
    } on Object {
      throw const EagerBackupFailure.transient();
    } finally {
      heartbeat?.cancel();
      final renewal = renewalInFlight;
      if (renewal != null) await renewal;
      final claimedActivity = activityClaim;
      if (claimedActivity != null) await _arbiter.endForegroundActivity(lease, claimedActivity);
      final drain = failedPermitDrain;
      if (drain != null) await drain;
      await _arbiter.releaseCurrentWhenQuiescent(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
    }
  }
}
