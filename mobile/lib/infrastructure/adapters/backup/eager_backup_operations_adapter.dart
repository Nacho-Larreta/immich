import 'dart:async';

import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';

final class EagerBackupOperationsAdapter implements EagerBackupOperationsPort {
  EagerBackupOperationsAdapter({
    required String? Function() readUserId,
    required DriftBackupRepository backups,
    required BackgroundSyncManager synchronization,
    required ForegroundUploadService uploads,
    required BackupExecutionArbiter arbiter,
    required BackupRunBindingSourcePort bindings,
    EagerBackgroundUploadPort backgroundUploads = const _UnavailableBackgroundUploads(),
    EagerBackupActivityProjectionPort activityProjection = const _NoOpBackupActivityProjection(),
    EagerBackupDiagnosticsPort diagnostics = const NoOpEagerBackupDiagnostics(),
    Duration backgroundWatchdog = const Duration(seconds: 30),
    Duration heartbeatInterval = const Duration(seconds: 30),
  }) : _readUserId = readUserId,
       _backups = backups,
       _synchronization = synchronization,
       _uploads = uploads,
       _arbiter = arbiter,
       _bindings = bindings,
       _backgroundUploads = backgroundUploads,
       _activityProjection = activityProjection,
       _diagnostics = FailSafeEagerBackupDiagnostics(diagnostics),
       _backgroundWatchdog = backgroundWatchdog,
       _heartbeatInterval = heartbeatInterval;

  final String? Function() _readUserId;
  final DriftBackupRepository _backups;
  final BackgroundSyncManager _synchronization;
  final ForegroundUploadService _uploads;
  final BackupExecutionArbiter _arbiter;
  final BackupRunBindingSourcePort _bindings;
  final EagerBackgroundUploadPort _backgroundUploads;
  final EagerBackupActivityProjectionPort _activityProjection;
  final EagerBackupDiagnosticsPort _diagnostics;
  final Duration _backgroundWatchdog;
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
  Future<EagerBackupUploadOutcome> upload(BackupRunBinding binding, EagerBackupCancellation cancellation) async {
    final admission = await _arbiter.acquireForeground(bindingDigest: binding.digest);
    final lease = admission.lease;
    _diagnostics.report(
      EagerBackupDiagnosticEvent(
        EagerBackupDiagnosticCode.admissionDecided,
        admissionDisposition: _diagnosticDispositionFor(admission.disposition),
        activeClaims: lease?.outstandingClaims.length,
      ),
    );
    if (!_bindings.isCurrent(binding)) {
      if (admission.admitted && lease != null) {
        await _arbiter.releaseCurrentWhenQuiescent(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
      }
      throw const EagerBackupFailure.bindingStale();
    }
    if (admission.disposition == BackupAdmissionDisposition.adoptedBackground) {
      if (lease == null) throw const EagerBackupFailure.recoveryPending();
      return _observeAdoptedBackground(lease, binding, cancellation);
    }
    if (!admission.admitted || lease == null) {
      throw _failureFor(admission);
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
      activityClaim = await _arbiter.beginForegroundActivity(lease, expectedNativeGeneration: binding.nativeGeneration);
      if (activityClaim == null) throw const EagerBackupFailure.bindingStale();
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
      final uploadResult = await _uploads.uploadCandidates(
        binding.userId,
        cancelToken,
        binding: binding,
        executionLease: lease,
        isBindingCurrent: (_) => isPermitCurrent(),
        callbacks: UploadCallbacks(
          onProgress: (id, filename, bytes, totalBytes) {
            if (!isPermitCurrent()) return;
            _activityProjection.presentActivity(
              BackupUploadActivity(
                kind: BackupUploadActivityKind.progress,
                localAssetId: id,
                filename: filename,
                progress: totalBytes > 0 ? bytes / totalBytes : 0,
                totalBytes: totalBytes,
              ),
            );
          },
          onSuccess: (id, _) {
            if (!isPermitCurrent()) return;
            _activityProjection.presentActivity(
              BackupUploadActivity(kind: BackupUploadActivityKind.success, localAssetId: id),
            );
          },
          onError: (id, error) {
            if (!isPermitCurrent()) return;
            failed = true;
            _activityProjection.presentActivity(
              BackupUploadActivity(kind: BackupUploadActivityKind.error, localAssetId: id, error: error),
            );
          },
          onICloudProgress: (id, progress) {
            if (!isPermitCurrent()) return;
            _activityProjection.presentActivity(
              BackupUploadActivity(kind: BackupUploadActivityKind.iCloudProgress, localAssetId: id, progress: progress),
            );
          },
        ),
      );
      final denial = uploadResult.denial;
      if (denial != null) return _eagerOutcomeFor(denial.reason);
      if (!isPermitCurrent()) throw const EagerBackupFailure.staleContext();
      if (failed) throw const EagerBackupFailure.transient();
      if (!await _synchronization.syncRemoteForBinding(binding)) throw const EagerBackupFailure.transient();
      if (!isPermitCurrent()) throw const EagerBackupFailure.staleContext();
      return EagerBackupUploadOutcome.completed;
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

  Future<EagerBackupUploadOutcome> _observeAdoptedBackground(
    BackupExecutionLease lease,
    BackupRunBinding binding,
    EagerBackupCancellation cancellation,
  ) async {
    final owner = EagerBackgroundUploadOwner.fromLease(lease);
    final terminal = Completer<_AdoptedBackgroundTerminal>();
    Timer? watchdog;
    void complete(_AdoptedBackgroundTerminal outcome) {
      if (!terminal.isCompleted) terminal.complete(outcome);
    }

    void renewWatchdog() {
      watchdog?.cancel();
      watchdog = Timer(_backgroundWatchdog, () => complete(_AdoptedBackgroundTerminal.inactive));
    }

    cancellation.onCancel(() {
      complete(_AdoptedBackgroundTerminal.cancelled);
    });
    if (!_bindings.isCurrent(binding)) throw const EagerBackupFailure.bindingStale();
    final subscription = _backgroundUploads
        .eventsFor(owner)
        .listen(
          (event) {
            if (!_bindings.isCurrent(binding)) {
              complete(_AdoptedBackgroundTerminal.bindingStale);
              return;
            }
            renewWatchdog();
            _activityProjection.presentActivity(event.activity);
            if (!_bindings.isCurrent(binding)) {
              complete(_AdoptedBackgroundTerminal.bindingStale);
              return;
            }
            final remaining = event.remainingActiveCount;
            if (remaining != null) {
              _activityProjection.presentBackgroundSnapshot(
                EagerBackgroundUploadSnapshot(activeCount: remaining, waitingToRetryCount: 0, pausedCount: 0),
              );
            }
            final outcome = event.terminal;
            final isTerminalFailure = outcome == EagerBackgroundUploadTerminal.failed;
            final isLastSuccess = outcome == EagerBackgroundUploadTerminal.succeeded && event.remainingActiveCount == 0;
            if ((isTerminalFailure || isLastSuccess) && !terminal.isCompleted) {
              complete(isTerminalFailure ? _AdoptedBackgroundTerminal.failed : _AdoptedBackgroundTerminal.succeeded);
            }
          },
          onError: (Object _, StackTrace __) {
            complete(_AdoptedBackgroundTerminal.failed);
          },
        );
    renewWatchdog();
    try {
      final snapshot = await _backgroundUploads.readSnapshot(owner).timeout(_backgroundWatchdog);
      if (!_bindings.isCurrent(binding)) throw const EagerBackupFailure.bindingStale();
      _activityProjection.presentBackgroundSnapshot(snapshot);
      if (!_bindings.isCurrent(binding)) throw const EagerBackupFailure.bindingStale();
      switch (snapshot.ownerState) {
        case EagerBackgroundOwnerState.completed:
          return EagerBackupUploadOutcome.completed;
        case EagerBackgroundOwnerState.recoveryPending:
          throw const EagerBackupFailure.recoveryPending();
        case EagerBackgroundOwnerState.authorityChanged:
          throw const EagerBackupFailure.bindingStale();
        case EagerBackgroundOwnerState.active:
          break;
      }
      final resumed = await _backgroundUploads.resumeOwned(owner).timeout(_backgroundWatchdog);
      if (!_bindings.isCurrent(binding)) throw const EagerBackupFailure.bindingStale();
      switch (resumed) {
        case EagerBackgroundResumeDisposition.completed:
          return EagerBackupUploadOutcome.completed;
        case EagerBackgroundResumeDisposition.recoveryPending:
          throw const EagerBackupFailure.recoveryPending();
        case EagerBackgroundResumeDisposition.authorityChanged:
          throw const EagerBackupFailure.bindingStale();
        case EagerBackgroundResumeDisposition.observing:
          break;
      }
      final outcome = await terminal.future;
      return switch (outcome) {
        _AdoptedBackgroundTerminal.succeeded => EagerBackupUploadOutcome.completed,
        _AdoptedBackgroundTerminal.failed => throw const EagerBackupFailure.transient(),
        _AdoptedBackgroundTerminal.bindingStale => throw const EagerBackupFailure.bindingStale(),
        _AdoptedBackgroundTerminal.cancelled ||
        _AdoptedBackgroundTerminal.inactive => throw const EagerBackupFailure.backgroundOwnerActive(),
      };
    } on TimeoutException {
      throw const EagerBackupFailure.recoveryPending();
    } finally {
      watchdog?.cancel();
      await subscription.cancel();
    }
  }

  static EagerBackupFailure _failureFor(BackupAdmission admission) => switch (admission.disposition) {
    BackupAdmissionDisposition.ownerActive => const EagerBackupFailure.backgroundOwnerActive(),
    BackupAdmissionDisposition.awaitingExpiry => EagerBackupFailure.awaitingLeaseExpiry(admission.retryAt),
    BackupAdmissionDisposition.recoveryPending => const EagerBackupFailure.recoveryPending(),
    BackupAdmissionDisposition.contention => const EagerBackupFailure.leaseContention(),
    BackupAdmissionDisposition.bindingStale => const EagerBackupFailure.bindingStale(),
    BackupAdmissionDisposition.acquired ||
    BackupAdmissionDisposition.adoptedBackground => const EagerBackupFailure.leaseContention(),
  };

  static EagerBackupAdmissionDisposition _diagnosticDispositionFor(BackupAdmissionDisposition disposition) =>
      switch (disposition) {
        BackupAdmissionDisposition.acquired => EagerBackupAdmissionDisposition.foregroundAcquired,
        BackupAdmissionDisposition.adoptedBackground => EagerBackupAdmissionDisposition.backgroundAdopted,
        BackupAdmissionDisposition.ownerActive => EagerBackupAdmissionDisposition.ownerActive,
        BackupAdmissionDisposition.awaitingExpiry => EagerBackupAdmissionDisposition.awaitingExpiry,
        BackupAdmissionDisposition.recoveryPending => EagerBackupAdmissionDisposition.recoveryPending,
        BackupAdmissionDisposition.contention => EagerBackupAdmissionDisposition.contention,
        BackupAdmissionDisposition.bindingStale => EagerBackupAdmissionDisposition.bindingStale,
      };

  EagerBackupUploadOutcome _eagerOutcomeFor(ForegroundUploadGateReason reason) => switch (reason) {
    ForegroundUploadGateReason.noWifi => EagerBackupUploadOutcome.noWifi,
    ForegroundUploadGateReason.transportCursorChanged => EagerBackupUploadOutcome.transportCursorChanged,
    ForegroundUploadGateReason.bindingStale => EagerBackupUploadOutcome.bindingStale,
    ForegroundUploadGateReason.evidenceUnavailable => EagerBackupUploadOutcome.evidenceUnavailable,
  };
}

final class _UnavailableBackgroundUploads implements EagerBackgroundUploadPort {
  const _UnavailableBackgroundUploads();

  @override
  Stream<EagerBackgroundUploadEvent> eventsFor(EagerBackgroundUploadOwner owner) => const Stream.empty();

  @override
  Future<EagerBackgroundUploadSnapshot> readSnapshot(EagerBackgroundUploadOwner owner) async =>
      const EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 0, pausedCount: 0);

  @override
  Future<EagerBackgroundResumeDisposition> resumeOwned(EagerBackgroundUploadOwner owner) async =>
      EagerBackgroundResumeDisposition.recoveryPending;
}

final class _NoOpBackupActivityProjection implements EagerBackupActivityProjectionPort {
  const _NoOpBackupActivityProjection();

  @override
  void presentActivity(BackupUploadActivity activity) {}

  @override
  void presentBackgroundSnapshot(EagerBackgroundUploadSnapshot snapshot) {}
}

enum _AdoptedBackgroundTerminal { succeeded, failed, bindingStale, cancelled, inactive }
