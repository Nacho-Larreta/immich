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

final class BackupTransportSnapshot {
  const BackupTransportSnapshot({required this.available, required this.capabilities, this.revision = 0});

  final bool available;
  final Set<BackupNetworkCapability> capabilities;
  final int revision;

  bool get hasWifi => available && capabilities.contains(BackupNetworkCapability.wifi);
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

enum EagerBackupFailureKind { transient, authentication, staleContext, deterministic, drainFailed }

final class EagerBackupFailure implements Exception {
  const EagerBackupFailure.transient() : kind = EagerBackupFailureKind.transient;
  const EagerBackupFailure.authentication() : kind = EagerBackupFailureKind.authentication;
  const EagerBackupFailure.staleContext() : kind = EagerBackupFailureKind.staleContext;
  const EagerBackupFailure.deterministic() : kind = EagerBackupFailureKind.deterministic;
  const EagerBackupFailure.drainFailed() : kind = EagerBackupFailureKind.drainFailed;

  final EagerBackupFailureKind kind;
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
