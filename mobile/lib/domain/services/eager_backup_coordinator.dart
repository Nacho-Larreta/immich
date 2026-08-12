import 'dart:async';
import 'dart:math';

import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';

final class EagerBackupCoordinator {
  EagerBackupCoordinator({
    required EagerBackupOperationsPort operations,
    EagerBackupRetryScheduler? retryScheduler,
    double Function()? jitter,
  }) : _operations = operations,
       _retryScheduler = retryScheduler ?? const _TimerRetryScheduler(),
       _jitter = jitter ?? (() => 0);

  final EagerBackupOperationsPort _operations;
  final EagerBackupRetryScheduler _retryScheduler;
  final double Function() _jitter;
  final StreamController<EagerBackupState> _states = StreamController<EagerBackupState>.broadcast(sync: true);

  EagerBackupState _state = const EagerBackupState(EagerBackupPhase.idle);
  EagerBackupState get state => _state;
  Stream<EagerBackupState> get states => _states.stream;

  bool _enabled = false;
  bool _foreground = false;
  bool _serverProofAvailable = false;
  bool _demand = false;
  bool _running = false;
  bool _disposed = false;
  bool _activated = false;
  BackupTransportSnapshot _transport = const BackupTransportSnapshot(available: false, capabilities: {});
  BackupWorkload? _preparedWorkload;
  EagerBackupCancellation? _cancellation;
  EagerBackupScheduledRetry? _scheduledRetry;
  int _retryAttempt = 0;

  void setEnabled(bool enabled) {
    _enabled = enabled;
    if (!enabled) {
      _demand = false;
      _preparedWorkload = null;
      _cancelActiveWork();
      _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.disabled);
      return;
    }
    signal(EagerBackupTrigger.settingChanged);
  }

  void setForeground(bool foreground) {
    _foreground = foreground;
    if (!foreground) {
      _cancelActiveWork();
      _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.paused);
      return;
    }
    _signalIfActivated(EagerBackupTrigger.resumed);
  }

  Future<bool> suspendForeground({Duration timeout = const Duration(seconds: 5)}) async {
    setForeground(false);
    final elapsed = Stopwatch()..start();
    while (_running) {
      if (elapsed.elapsed >= timeout) return false;
      await Future<void>.delayed(Duration.zero);
    }
    return true;
  }

  void setTransport(BackupTransportSnapshot transport) {
    final lostWifi = _transport.hasWifi && !transport.hasWifi;
    _transport = transport;
    if (lostWifi) {
      _demand = true;
      _cancelActiveWork();
      _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.noWifi);
    }
    _signalIfActivated(EagerBackupTrigger.connectivityChanged);
  }

  void setServerProofAvailable(bool available) {
    final lostProof = _serverProofAvailable && !available;
    _serverProofAvailable = available;
    if (lostProof) {
      _demand = true;
      _cancelActiveWork();
      _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.noProof);
    }
    _signalIfActivated(EagerBackupTrigger.serverProofChanged);
  }

  void reportDrainFailed() {
    _demand = true;
    _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.drainFailed);
  }

  void reportLeaseOwned() {
    _demand = true;
    _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.leaseOwned);
  }

  void signal(EagerBackupTrigger trigger) {
    if (_disposed || !_enabled) return;
    _activated = true;
    if (trigger == EagerBackupTrigger.uploadFailed) {
      _demand = true;
      _scheduledRetry?.cancel();
      _scheduleRetry();
      return;
    }
    if (trigger == EagerBackupTrigger.reconciliationPending) {
      _demand = true;
      _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.reconciliationPending);
      return;
    }
    if (trigger == EagerBackupTrigger.reconciliationBlocked) {
      _demand = true;
      _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.reconciliationBlocked);
      return;
    }
    if (_invalidatesPreparation(trigger)) _preparedWorkload = null;
    _demand = true;
    _scheduledRetry?.cancel();
    _scheduledRetry = null;
    if (_foreground) unawaited(_drain());
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _demand = false;
    _cancelActiveWork();
    _setState(EagerBackupPhase.disposed);
    while (_running) {
      await Future<void>.delayed(Duration.zero);
    }
    await _states.close();
  }

  Future<void> _drain() async {
    if (_running || _disposed || !_enabled || !_foreground) return;
    _running = true;
    EagerBackupCancellation? runCancellation;
    try {
      while (_demand && !_disposed && _enabled && _foreground) {
        _demand = false;
        final cancellation = EagerBackupCancellation();
        runCancellation = cancellation;
        _cancellation = cancellation;
        try {
          var workload = _preparedWorkload;
          if (workload == null) {
            _setState(EagerBackupPhase.evaluating);
            workload = await _operations.readWorkload();
            if (_mustStop(cancellation)) return;
            if (!workload.hasDemand) {
              _retryAttempt = 0;
              _setState(EagerBackupPhase.idle);
              continue;
            }

            _setState(EagerBackupPhase.preparing);
            await _operations.synchronizeLocal(cancellation);
            if (_mustStop(cancellation)) return;
            workload = await _operations.readWorkload();
            if (_mustStop(cancellation)) return;
            if (workload.processing > 0) {
              await _operations.hashAssets(cancellation);
              if (_mustStop(cancellation)) return;
              workload = await _operations.readWorkload();
              if (_mustStop(cancellation)) return;
            }
            _preparedWorkload = workload;
          }
          if (!workload.hasDemand) {
            _retryAttempt = 0;
            _setState(EagerBackupPhase.idle);
            continue;
          }
          if (!_canUpload || workload.ready == 0) {
            _demand = true;
            _setState(
              EagerBackupPhase.blocked,
              blocker: !_transport.hasWifi ? EagerBackupBlocker.noWifi : EagerBackupBlocker.noProof,
            );
            return;
          }

          final binding = await _operations.captureBinding();
          if (_mustStop(cancellation)) return;
          if (binding == null) {
            _demand = true;
            _setState(EagerBackupPhase.blocked, blocker: EagerBackupBlocker.noProof);
            return;
          }
          _setState(EagerBackupPhase.uploading);
          await _operations.upload(binding, cancellation);
          if (_mustStop(cancellation)) return;
          _retryAttempt = 0;
          _preparedWorkload = null;
          _demand = true;
        } on EagerBackupFailure catch (failure) {
          if (_mustStop(cancellation)) return;
          if (failure.kind == EagerBackupFailureKind.transient) {
            _demand = true;
            _scheduleRetry();
          } else {
            _demand = true;
            _setState(EagerBackupPhase.blocked, blocker: _blockerFor(failure.kind));
          }
          return;
        } on Object {
          if (_mustStop(cancellation)) return;
          _demand = true;
          _scheduleRetry();
          return;
        }
      }
    } finally {
      if (identical(_cancellation, runCancellation)) _cancellation = null;
      _running = false;
    }
  }

  bool get _canUpload => _foreground && _transport.hasWifi && _serverProofAvailable;

  bool _mustStop(EagerBackupCancellation cancellation) =>
      cancellation.isCancelled || _disposed || !_enabled || !_foreground;

  void _cancelActiveWork() {
    _scheduledRetry?.cancel();
    _scheduledRetry = null;
    _cancellation?.cancel();
  }

  void _scheduleRetry() {
    final seconds = const [1, 2, 4, 8, 15, 30][min(_retryAttempt, 5)];
    _retryAttempt++;
    final jitteredMillis = (seconds * 1000 * (1 + (_jitter().clamp(-1, 1) * 0.1))).round();
    _setState(EagerBackupPhase.backingOff);
    _scheduledRetry = _retryScheduler.schedule(Duration(milliseconds: jitteredMillis), () {
      _scheduledRetry = null;
      signal(EagerBackupTrigger.retry);
    });
  }

  void _signalIfActivated(EagerBackupTrigger trigger) {
    if (_activated) signal(trigger);
  }

  static bool _invalidatesPreparation(EagerBackupTrigger trigger) => switch (trigger) {
    EagerBackupTrigger.connectivityChanged ||
    EagerBackupTrigger.serverProofChanged ||
    EagerBackupTrigger.retry ||
    EagerBackupTrigger.uploadTerminal => false,
    EagerBackupTrigger.uploadFailed => false,
    EagerBackupTrigger.reconciliationPending => false,
    EagerBackupTrigger.reconciliationBlocked => false,
    _ => true,
  };

  static EagerBackupBlocker _blockerFor(EagerBackupFailureKind kind) => switch (kind) {
    EagerBackupFailureKind.authentication => EagerBackupBlocker.noProof,
    EagerBackupFailureKind.staleContext => EagerBackupBlocker.leaseOwned,
    EagerBackupFailureKind.deterministic => EagerBackupBlocker.deterministicFailure,
    EagerBackupFailureKind.drainFailed => EagerBackupBlocker.drainFailed,
    EagerBackupFailureKind.transient => EagerBackupBlocker.drainFailed,
  };

  void _setState(EagerBackupPhase phase, {EagerBackupBlocker? blocker}) {
    _state = EagerBackupState(phase, retryAttempt: _retryAttempt, blocker: blocker, workload: _preparedWorkload);
    if (!_states.isClosed) _states.add(_state);
  }
}

final class _TimerRetryScheduler implements EagerBackupRetryScheduler {
  const _TimerRetryScheduler();

  @override
  EagerBackupScheduledRetry schedule(Duration delay, void Function() callback) => _TimerRetry(Timer(delay, callback));
}

final class _TimerRetry implements EagerBackupScheduledRetry {
  const _TimerRetry(this._timer);
  final Timer _timer;

  @override
  void cancel() => _timer.cancel();
}
