import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';

enum BackupAdmissionDisposition {
  acquired,
  adoptedBackground,
  ownerActive,
  awaitingExpiry,
  recoveryPending,
  contention,
  bindingStale,
}

final class BackupAdmission {
  const BackupAdmission(this.disposition, {this.lease, this.retryAt});

  final BackupAdmissionDisposition disposition;
  final BackupExecutionLease? lease;
  final DateTime? retryAt;

  bool get admitted => disposition == BackupAdmissionDisposition.acquired;
}

abstract interface class BackgroundBackupAdmissionPort {
  Future<BackupAdmission> acquireBackground({required String bindingDigest});

  Future<void> releaseCurrentWhenQuiescent({required String runToken, required String bindingDigest});
}

final class BackupExecutionArbiter implements BackgroundBackupAdmissionPort {
  BackupExecutionArbiter({
    required BackupExecutionLeasePort leases,
    required BackupTaskRegistryPort tasks,
    ForegroundTransportFencePort? foregroundFence,
    BackupCallbackFencePort? callbackFence,
    DateTime Function()? clock,
    String Function()? tokenFactory,
    Duration leaseDuration = const Duration(minutes: 2),
  }) : _leases = leases,
       _tasks = tasks,
       _foregroundFence = foregroundFence ?? const _RejectingForegroundTransportFence(),
       _callbackFence = callbackFence ?? const _RejectingBackupCallbackFence(),
       _clock = clock ?? DateTime.now,
       _tokenFactory = tokenFactory ?? _secureToken,
       _leaseDuration = leaseDuration;

  static const groups = {BackupTaskGroup.primary, BackupTaskGroup.livePhoto};

  final BackupExecutionLeasePort _leases;
  final BackupTaskRegistryPort _tasks;
  final ForegroundTransportFencePort _foregroundFence;
  final BackupCallbackFencePort _callbackFence;
  final DateTime Function() _clock;
  final String Function() _tokenFactory;
  final Duration _leaseDuration;
  final Map<String, Future<bool>> _disableOperations = {};

  Future<BackupAdmission> acquireForeground({required String bindingDigest}) async {
    return _acquire(mode: BackupExecutionMode.foreground, bindingDigest: bindingDigest);
  }

  @override
  Future<BackupAdmission> acquireBackground({required String bindingDigest}) async {
    return _acquire(mode: BackupExecutionMode.background, bindingDigest: bindingDigest);
  }

  Future<BackupAdmission> _acquire({required BackupExecutionMode mode, required String bindingDigest}) async {
    await _tasks.ready;
    var active = (await _tasks.snapshot(groups)).where((task) => task.isActive).toList(growable: false);
    var existing = await _leases.read();
    final ownership = _classify(active, bindingDigest);
    if (ownership case _OwnedTasks(:final runToken, :final digest)) {
      if (existing != null && existing.runToken == runToken && existing.bindingDigest == digest) {
        if (existing.state == BackupExecutionState.closing) {
          existing = await _leases.reconcileTaskClaimsForOwner(
            runToken: runToken,
            bindingDigest: digest,
            activeClaims: _claimsFor(active),
          );
          return existing == null
              ? const BackupAdmission(BackupAdmissionDisposition.contention)
              : BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: existing);
        }
        if (existing.isExpiredAt(_clock())) {
          existing = await _renewExact(existing);
          if (existing == null) return const BackupAdmission(BackupAdmissionDisposition.contention);
        }
        existing = await _leases.reconcileTaskClaimsForOwner(
          runToken: runToken,
          bindingDigest: digest,
          activeClaims: _claimsFor(active),
        );
        if (existing == null) return const BackupAdmission(BackupAdmissionDisposition.contention);
        return BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: existing);
      }
      if (!await _drainInconsistent(existing)) {
        return const BackupAdmission(BackupAdmissionDisposition.bindingStale);
      }
      active = await _activeTasks();
      if (active.isNotEmpty) return const BackupAdmission(BackupAdmissionDisposition.ownerActive);
      existing = await _leases.read();
    } else if (ownership is _InconsistentTasks) {
      if (!await _drainInconsistent(existing)) {
        return const BackupAdmission(BackupAdmissionDisposition.bindingStale);
      }
      active = await _activeTasks();
      if (active.isNotEmpty) return const BackupAdmission(BackupAdmissionDisposition.ownerActive);
      existing = await _leases.read();
    }

    if (active.isEmpty && existing != null && _hasExactBackgroundClaims(existing, bindingDigest)) {
      return BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: existing);
    }

    if (active.isEmpty && existing != null && existing.isExpiredAt(_clock())) {
      if (existing.state == BackupExecutionState.accepting) {
        existing = await _leases.beginClosingForOwner(
          runToken: existing.runToken,
          bindingDigest: existing.bindingDigest,
        );
        if (existing == null) return const BackupAdmission(BackupAdmissionDisposition.contention);
      }
      if (existing.state == BackupExecutionState.closing) {
        final recovered = await _recoverExpiredClosing(existing);
        if (!recovered) return BackupAdmission(BackupAdmissionDisposition.recoveryPending, lease: existing);
        existing = await _leases.read();
      }
      if (existing != null && existing.hasDurableActivity) {
        return BackupAdmission(BackupAdmissionDisposition.recoveryPending, lease: existing);
      }
    }

    if (active.isEmpty && existing != null && !existing.isExpiredAt(_clock())) {
      return BackupAdmission(BackupAdmissionDisposition.awaitingExpiry, lease: existing, retryAt: existing.expiresAt);
    }

    final now = _clock();
    final candidate = BackupExecutionLease(
      mode: mode,
      runToken: _tokenFactory(),
      bindingDigest: bindingDigest,
      expiresAt: now.add(_leaseDuration),
      activityRevision: 0,
      callbacksInFlight: 0,
    );
    if (!await _leases.acquire(candidate, now)) {
      return const BackupAdmission(BackupAdmissionDisposition.contention);
    }

    final postAcquireTasks = await _activeTasks();
    if (postAcquireTasks.isNotEmpty) {
      await _leases.releaseExact(candidate);
      return const BackupAdmission(BackupAdmissionDisposition.ownerActive);
    }
    return BackupAdmission(BackupAdmissionDisposition.acquired, lease: candidate);
  }

  Future<bool> releaseWhenQuiescent(BackupExecutionLease expected) async {
    await _tasks.ready;
    final current = await _leases.read();
    if (current != expected || current!.hasDurableActivity) return false;
    final firstTasks = await _activeTasks();
    if (firstTasks.isNotEmpty) return false;
    if (await _leases.read() != expected) return false;
    await Future<void>.delayed(Duration.zero);
    final afterDrain = await _leases.read();
    if (afterDrain != expected || afterDrain!.hasDurableActivity) return false;
    final secondTasks = await _activeTasks();
    if (secondTasks.isNotEmpty) return false;
    if (await _leases.read() != expected) return false;
    return _leases.releaseExact(expected);
  }

  @override
  Future<bool> releaseCurrentWhenQuiescent({required String runToken, required String bindingDigest}) async {
    final lease = await _leases.read();
    if (lease == null || lease.runToken != runToken || lease.bindingDigest != bindingDigest) return false;
    return releaseWhenQuiescent(lease);
  }

  Future<BackupExecutionLease?> renewCurrent({required String runToken, required String bindingDigest}) async {
    final current = await _leases.read();
    if (current == null ||
        current.runToken != runToken ||
        current.bindingDigest != bindingDigest ||
        current.state == BackupExecutionState.closing) {
      return null;
    }
    final renewed = current.copyWith(
      expiresAt: _clock().add(_leaseDuration),
      activityRevision: current.activityRevision + 1,
    );
    return await _leases.replaceExact(expected: current, replacement: renewed) ? renewed : null;
  }

  Future<ForegroundTransportClaim?> beginForegroundActivity(
    BackupExecutionLease owner, {
    required int expectedNativeGeneration,
  }) async {
    final identity = await _foregroundFence.captureIdentity();
    if (identity == null ||
        identity.generation != expectedNativeGeneration ||
        !_foregroundFence.isIdentityCurrent(identity, bindingDigest: owner.bindingDigest)) {
      return null;
    }
    final claim = ForegroundTransportClaim.current(
      activityId: _tokenFactory(),
      bindingDigest: owner.bindingDigest,
      nativeGeneration: identity.generation,
      transportIncarnation: identity.incarnation,
    );
    final claimed = await _leases.beginForegroundActivityForOwner(
      runToken: owner.runToken,
      bindingDigest: owner.bindingDigest,
      claim: claim,
    );
    if (claimed == null) return null;
    if (_foregroundFence.isIdentityCurrent(identity, bindingDigest: owner.bindingDigest)) return claim;
    final rolledBack = await _leases.endForegroundActivityForOwner(
      runToken: owner.runToken,
      bindingDigest: owner.bindingDigest,
      claim: claim,
    );
    if (rolledBack == null) {
      throw StateError('Foreground transport authority changed and its durable claim could not be rolled back');
    }
    return null;
  }

  Future<bool> endForegroundActivity(BackupExecutionLease owner, ForegroundTransportClaim claim) async {
    return await _leases.endForegroundActivityForOwner(
          runToken: owner.runToken,
          bindingDigest: owner.bindingDigest,
          claim: claim,
        ) !=
        null;
  }

  Future<bool> disableAndDrain({
    required String runToken,
    required String bindingDigest,
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final operationKey = '$runToken:$bindingDigest';
    final inFlight = _disableOperations[operationKey];
    if (inFlight != null) return inFlight;
    final operation = _disableAndDrain(runToken: runToken, bindingDigest: bindingDigest, timeout: timeout);
    _disableOperations[operationKey] = operation;
    try {
      return await operation;
    } finally {
      if (identical(_disableOperations[operationKey], operation)) {
        final _ = _disableOperations.remove(operationKey);
      }
    }
  }

  Future<bool> _disableAndDrain({
    required String runToken,
    required String bindingDigest,
    required Duration timeout,
  }) async {
    await _tasks.ready;
    final observed = await _leases.read();
    final closing = await _leases.beginClosingForOwner(runToken: runToken, bindingDigest: bindingDigest);
    if (closing == null) return false;
    final resumesExpiredClosing =
        observed == closing && closing.state == BackupExecutionState.closing && closing.isExpiredAt(_clock());
    if (resumesExpiredClosing) {
      return _recoverExpiredClosing(closing, timeout: timeout);
    }
    const pollInterval = Duration(milliseconds: 20);
    final maxPolls = max(1, (timeout.inMicroseconds / pollInterval.inMicroseconds).ceil());
    for (var poll = 0; poll < maxPolls; poll++) {
      final current = await _leases.read();
      if (current == null || current.runToken != runToken || current.bindingDigest != bindingDigest) return false;
      if (current.enqueueClaims.isEmpty && current.foregroundActivityClaims.isEmpty && current.callbacksInFlight == 0) {
        break;
      }
      if (poll + 1 == maxPolls) return false;
      await Future<void>.delayed(pollInterval);
    }
    if (!await _tasks.cancelAndDrain(groups)) return false;
    final active = await _activeTasks();
    final reconciled = await _leases.reconcileTaskClaimsForOwner(
      runToken: runToken,
      bindingDigest: bindingDigest,
      activeClaims: _claimsFor(active),
    );
    if (reconciled == null) return false;
    return releaseWhenQuiescent(reconciled);
  }

  Future<BackupExecutionLease?> _renewExact(BackupExecutionLease current) async {
    final renewed = current.copyWith(
      expiresAt: _clock().add(_leaseDuration),
      activityRevision: current.activityRevision + 1,
    );
    return await _leases.replaceExact(expected: current, replacement: renewed) ? renewed : null;
  }

  Future<bool> _drainInconsistent(BackupExecutionLease? expected) async {
    if (expected == null) return _tasks.cancelAndDrain(groups);
    return disableAndDrain(runToken: expected.runToken, bindingDigest: expected.bindingDigest);
  }

  Future<bool> _recoverExpiredClosing(
    BackupExecutionLease expected, {
    Duration timeout = const Duration(seconds: 5),
  }) async {
    final q1 = await _activeTasks();
    if (q1.isNotEmpty) return false;
    if (await _leases.read() != expected) return false;
    await Future<void>.delayed(Duration.zero);
    if (await _leases.read() != expected) return false;
    final q2 = await _activeTasks();
    if (q2.isNotEmpty) return false;
    if (await _leases.read() != expected) return false;
    if (!await _callbackFence.fenceAndDrain(
      runToken: expected.runToken,
      bindingDigest: expected.bindingDigest,
      timeout: timeout,
    )) {
      return false;
    }
    if (await _leases.read() != expected) return false;
    final foregroundClaims = expected.foregroundActivityClaims;
    if (foregroundClaims.isNotEmpty) {
      final retirement = await _foregroundFence.retireClaims(foregroundClaims, timeout: timeout);
      if (retirement != ForegroundTransportRetirement.retired) return false;
    }
    if (await _leases.read() != expected) return false;
    final recovered = await _leases.recoverExpiredClosingExact(expected: expected, activeClaims: const {});
    if (recovered == null || recovered.hasDurableActivity) return false;
    return releaseWhenQuiescent(recovered);
  }

  Future<List<BackupTaskSnapshot>> _activeTasks() async {
    final snapshot = await _tasks.snapshot(groups);
    return snapshot.where((task) => task.isActive).toList(growable: false);
  }

  static Set<BackupTaskClaim> _claimsFor(Iterable<BackupTaskSnapshot> tasks) =>
      tasks.map((task) => BackupTaskClaim(group: task.group, taskId: task.taskId)).toSet();

  static bool _hasExactBackgroundClaims(BackupExecutionLease lease, String bindingDigest) =>
      lease.bindingDigest == bindingDigest &&
      (lease.outstandingClaims.isNotEmpty || lease.enqueueClaims.isNotEmpty || lease.reconciliationClaims.isNotEmpty);

  static _TaskOwnership _classify(List<BackupTaskSnapshot> tasks, String bindingDigest) {
    if (tasks.isEmpty) return const _EmptyTasks();
    final metadata = tasks.map((task) => task.metadata).toList();
    if (metadata.any((value) => value == null)) return const _InconsistentTasks();
    final values = metadata.cast<BackupTaskMetadata>();
    final tokens = values.map((value) => value.runToken).toSet();
    final bindings = values.map((value) => value.bindingDigest).toSet();
    if (tokens.length == 1 && bindings.length == 1 && bindings.single == bindingDigest) {
      return _OwnedTasks(runToken: tokens.single, digest: bindings.single);
    }
    return const _InconsistentTasks();
  }

  static String _secureToken() {
    final random = Random.secure();
    final bytes = List<int>.generate(16, (_) => random.nextInt(256));
    return base64UrlEncode(bytes).replaceAll('=', '');
  }
}

final class _RejectingForegroundTransportFence implements ForegroundTransportFencePort {
  const _RejectingForegroundTransportFence();

  @override
  Future<ForegroundTransportIdentity?> captureIdentity() async => null;

  @override
  bool isIdentityCurrent(ForegroundTransportIdentity identity, {required String bindingDigest}) => false;

  @override
  Future<ForegroundTransportRetirement> retireClaims(
    Set<ForegroundTransportClaim> claims, {
    required Duration timeout,
  }) async => ForegroundTransportRetirement.unsupported;
}

final class _RejectingBackupCallbackFence implements BackupCallbackFencePort {
  const _RejectingBackupCallbackFence();

  @override
  void end(BackupCallbackPermit permit) {}

  @override
  Future<bool> fenceAndDrain({
    required String runToken,
    required String bindingDigest,
    required Duration timeout,
  }) async => false;

  @override
  BackupCallbackPermit? tryBegin({required String runToken, required String bindingDigest}) => null;
}

sealed class _TaskOwnership {
  const _TaskOwnership();
}

final class _EmptyTasks extends _TaskOwnership {
  const _EmptyTasks();
}

final class _InconsistentTasks extends _TaskOwnership {
  const _InconsistentTasks();
}

final class _OwnedTasks extends _TaskOwnership {
  const _OwnedTasks({required this.runToken, required this.digest});

  final String runToken;
  final String digest;
}
