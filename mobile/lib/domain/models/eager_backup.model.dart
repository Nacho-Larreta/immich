import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';

enum EagerBackupPhase { idle, evaluating, preparing, uploading, backingOff, blocked, disposed }

enum EagerBackupBlocker {
  noWifi,
  noProof,
  leaseOwned,
  drainFailed,
  deterministicFailure,
  reconciliationPending,
  reconciliationBlocked,
  disabled,
  paused,
  bindingStale,
  evidenceUnavailable,
  backgroundOwnerActive,
  leaseAwaitingExpiry,
  leaseRecoveryPending,
  leaseContention,
}

enum EagerBackupTrigger {
  startup,
  settingChanged,
  albumSelectionChanged,
  workloadChanged,
  photoLibraryChanged,
  resumed,
  connectivityChanged,
  serverProofChanged,
  localTerminal,
  hashTerminal,
  uploadTerminal,
  uploadFailed,
  reconciliationPending,
  reconciliationBlocked,
  retry,
}

enum BackupNetworkCapability { wifi, cellular, vpn, unmetered }

enum EagerBackupUploadOutcome { completed, noWifi, transportCursorChanged, bindingStale, evidenceUnavailable }

enum EagerBackupAdmissionDisposition {
  foregroundAcquired,
  backgroundAdopted,
  ownerActive,
  awaitingExpiry,
  recoveryPending,
  contention,
  bindingStale,
}

enum EagerBackgroundUploadTerminal { succeeded, failed }

enum EagerBackgroundOwnerState { active, completed, recoveryPending, authorityChanged }

enum EagerBackgroundResumeDisposition { observing, completed, recoveryPending, authorityChanged }

final class EagerBackgroundUploadOwner {
  EagerBackgroundUploadOwner({
    required this.runToken,
    required this.bindingDigest,
    required Set<BackupTaskClaim> claims,
  }) : claims = Set.unmodifiable(claims);

  factory EagerBackgroundUploadOwner.fromLease(BackupExecutionLease lease) => EagerBackgroundUploadOwner(
    runToken: lease.runToken,
    bindingDigest: lease.bindingDigest,
    claims: {...lease.outstandingClaims, ...lease.enqueueClaims, ...lease.reconciliationClaims},
  );

  final String runToken;
  final String bindingDigest;
  final Set<BackupTaskClaim> claims;
}

final class EagerBackgroundUploadSnapshot {
  const EagerBackgroundUploadSnapshot({
    required this.activeCount,
    required this.waitingToRetryCount,
    required this.pausedCount,
    this.ownerState = EagerBackgroundOwnerState.active,
  }) : assert(activeCount >= 0),
       assert(waitingToRetryCount >= 0),
       assert(pausedCount >= 0);

  final int activeCount;
  final int waitingToRetryCount;
  final int pausedCount;
  final EagerBackgroundOwnerState ownerState;

  @override
  bool operator ==(Object other) =>
      other is EagerBackgroundUploadSnapshot &&
      other.activeCount == activeCount &&
      other.waitingToRetryCount == waitingToRetryCount &&
      other.pausedCount == pausedCount &&
      other.ownerState == ownerState;

  @override
  int get hashCode => Object.hash(activeCount, waitingToRetryCount, pausedCount, ownerState);
}

enum BackupUploadActivityKind { status, progress, success, iCloudProgress, error }

final class BackupUploadActivity {
  const BackupUploadActivity({
    required this.kind,
    required this.localAssetId,
    this.filename,
    this.progress,
    this.totalBytes,
    this.error,
  });

  final BackupUploadActivityKind kind;
  final String localAssetId;
  final String? filename;
  final double? progress;
  final int? totalBytes;
  final String? error;
}

final class EagerBackgroundUploadEvent {
  const EagerBackgroundUploadEvent({required this.activity, this.terminal, this.remainingActiveCount})
    : assert(remainingActiveCount == null || remainingActiveCount >= 0);

  final BackupUploadActivity activity;
  final EagerBackgroundUploadTerminal? terminal;
  final int? remainingActiveCount;
}

enum ForegroundUploadGateStage { preCandidate, preStorage, preFile, preReservation, preUpload }

enum ForegroundUploadGateReason { noWifi, transportCursorChanged, bindingStale, evidenceUnavailable }

final class ForegroundUploadGateDenial {
  const ForegroundUploadGateDenial({required this.stage, required this.reason});

  final ForegroundUploadGateStage stage;
  final ForegroundUploadGateReason reason;

  @override
  bool operator ==(Object other) =>
      other is ForegroundUploadGateDenial && other.stage == stage && other.reason == reason;

  @override
  int get hashCode => Object.hash(stage, reason);
}

final class ForegroundUploadResult {
  const ForegroundUploadResult.completed() : denial = null;

  const ForegroundUploadResult.denied(this.denial);

  final ForegroundUploadGateDenial? denial;

  bool get completed => denial == null;

  @override
  bool operator ==(Object other) => other is ForegroundUploadResult && other.denial == denial;

  @override
  int get hashCode => denial.hashCode;
}

final class BackupTransportSnapshot {
  const BackupTransportSnapshot({
    required this.available,
    required this.capabilities,
    this.monitorEpoch = 0,
    this.revision = 0,
  });

  final bool available;
  final Set<BackupNetworkCapability> capabilities;
  final int monitorEpoch;
  final int revision;

  bool get hasWifi => available && capabilities.contains(BackupNetworkCapability.wifi);

  bool isNewerThan(BackupTransportSnapshot other) =>
      monitorEpoch > other.monitorEpoch || (monitorEpoch == other.monitorEpoch && revision > other.revision);

  bool hasSameCursorAs(BackupTransportSnapshot other) =>
      monitorEpoch == other.monitorEpoch && revision == other.revision;

  bool hasSamePayloadAs(BackupTransportSnapshot other) =>
      available == other.available &&
      capabilities.length == other.capabilities.length &&
      capabilities.containsAll(other.capabilities);
}

final class BackupWorkload {
  const BackupWorkload({required this.total, required this.remainder, required this.processing})
    : assert(total >= 0),
      assert(remainder >= 0),
      assert(processing >= 0),
      assert(processing <= remainder),
      assert(remainder <= total);

  final int total;
  final int remainder;
  final int processing;

  int get ready => remainder - processing;
  bool get hasDemand => remainder > 0;
}

final class EagerBackupState {
  const EagerBackupState(this.phase, {this.retryAttempt = 0, this.blocker, this.workload});

  final EagerBackupPhase phase;
  final int retryAttempt;
  final EagerBackupBlocker? blocker;
  final BackupWorkload? workload;
}

enum EagerBackupFailureKind {
  transient,
  authentication,
  staleContext,
  deterministic,
  drainFailed,
  backgroundOwnerActive,
  awaitingLeaseExpiry,
  recoveryPending,
  leaseContention,
  bindingStale,
}

final class EagerBackupFailure implements Exception {
  const EagerBackupFailure.transient() : kind = EagerBackupFailureKind.transient, retryAt = null;
  const EagerBackupFailure.authentication() : kind = EagerBackupFailureKind.authentication, retryAt = null;
  const EagerBackupFailure.staleContext() : kind = EagerBackupFailureKind.staleContext, retryAt = null;
  const EagerBackupFailure.deterministic() : kind = EagerBackupFailureKind.deterministic, retryAt = null;
  const EagerBackupFailure.drainFailed() : kind = EagerBackupFailureKind.drainFailed, retryAt = null;
  const EagerBackupFailure.backgroundOwnerActive()
    : kind = EagerBackupFailureKind.backgroundOwnerActive,
      retryAt = null;
  const EagerBackupFailure.awaitingLeaseExpiry(this.retryAt) : kind = EagerBackupFailureKind.awaitingLeaseExpiry;
  const EagerBackupFailure.recoveryPending() : kind = EagerBackupFailureKind.recoveryPending, retryAt = null;
  const EagerBackupFailure.leaseContention() : kind = EagerBackupFailureKind.leaseContention, retryAt = null;
  const EagerBackupFailure.bindingStale() : kind = EagerBackupFailureKind.bindingStale, retryAt = null;

  final EagerBackupFailureKind kind;
  final DateTime? retryAt;
}

final class EagerBackupCancellation {
  bool _cancelled = false;
  final List<void Function()> _listeners = [];

  bool get isCancelled => _cancelled;

  void onCancel(void Function() listener) {
    if (_cancelled) {
      listener();
    } else {
      _listeners.add(listener);
    }
  }

  void cancel() {
    if (_cancelled) return;
    _cancelled = true;
    final listeners = List<void Function()>.of(_listeners);
    _listeners.clear();
    for (final listener in listeners) {
      listener();
    }
  }
}
