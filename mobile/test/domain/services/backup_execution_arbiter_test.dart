import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_reconciliation_quarantine.model.dart';
import 'package:immich_mobile/domain/services/backup_callback_fence.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';

void main() {
  test('snapshot index preserves duplicate task ids across distinct groups', () {
    final index = BackupTaskSnapshotIndex()
      ..add(
        const BackupTaskSnapshot(taskId: 'same-id', group: BackupTaskGroup.primary, status: BackupTaskStatus.running),
      )
      ..add(
        const BackupTaskSnapshot(taskId: 'same-id', group: BackupTaskGroup.livePhoto, status: BackupTaskStatus.paused),
      );

    expect(index.values, hasLength(2));
    expect(index.values.map((task) => task.group), {BackupTaskGroup.primary, BackupTaskGroup.livePhoto});
  });

  test('awaits registry readiness and restores active states from both groups', () async {
    final registry = _Registry(ready: Completer<void>());
    final leases = _Leases(existing: _lease('background-token', 'same-binding', DateTime.now()));
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, tokenFactory: () => 'foreground-token');
    registry.snapshots = [
      const BackupTaskSnapshot(
        taskId: 'opaque-a',
        group: BackupTaskGroup.primary,
        status: BackupTaskStatus.waitingToRetry,
        metadata: BackupTaskMetadata.current(
          runToken: 'background-token',
          bindingDigest: 'same-binding',
          phase: BackupTaskPhase.primary,
        ),
      ),
      const BackupTaskSnapshot(
        taskId: 'opaque-b',
        group: BackupTaskGroup.livePhoto,
        status: BackupTaskStatus.paused,
        metadata: BackupTaskMetadata.current(
          runToken: 'background-token',
          bindingDigest: 'same-binding',
          phase: BackupTaskPhase.livePhoto,
        ),
      ),
    ];

    final pending = arbiter.acquireForeground(bindingDigest: 'same-binding');
    await pumpEventQueue();
    expect(registry.snapshotCalls, 0);
    registry.completeReady();

    final result = await pending;
    expect(result.disposition, BackupAdmissionDisposition.adoptedBackground);
    expect(registry.requestedGroups, {BackupTaskGroup.primary, BackupTaskGroup.livePhoto});
    expect(registry.cancelAndDrainCalls, 0);
    expect(leases.acquireCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('non-expired empty lease returns its retry deadline without mutation', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final lease = _lease('background-token', 'same-binding', now);
    final leases = _Leases(existing: lease);
    final registry = _Registry();
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same-binding');

    expect(result.disposition, BackupAdmissionDisposition.awaitingExpiry);
    expect(result.retryAt, lease.expiresAt);
    expect(registry.cancelAndDrainCalls, 0);
    expect(leases.acquireCalls, 0);
    expect(leases.releaseCalls, 0);
    expect(leases.existing, lease);
  });

  test('lease with an exact durable background claim is adopted so its native mailbox can be replayed', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'mailbox-terminal');
    final lease = _lease('background-token', 'same-binding', now).copyWith(outstandingClaims: {claim});
    final leases = _Leases(existing: lease);
    final registry = _Registry();
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same-binding');

    expect(result.disposition, BackupAdmissionDisposition.adoptedBackground);
    expect(result.lease, lease);
    expect(registry.cancelAndDrainCalls, 0);
    expect(leases.recoverExactCalls, 0);
    expect(leases.acquireCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('expired orphan recovery fails closed with a typed pending disposition', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final orphan = _lease(
      'orphan',
      'same-binding',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, callbacksInFlight: 1);
    final leases = _Leases(existing: orphan);
    final registry = _Registry()..snapshotSequence = [const [], const []];
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same-binding');

    expect(result.disposition, BackupAdmissionDisposition.recoveryPending);
    expect(leases.existing, orphan);
    expect(leases.acquireCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('expired empty lease uses fenced recovery before a new admission', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final expired = _lease('orphan', 'same-binding', now.subtract(const Duration(minutes: 2)));
    final leases = _Leases(existing: expired);
    final registry = _Registry()..snapshotSequence = [const [], const [], const [], const [], const []];
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: registry,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
      tokenFactory: () => 'replacement',
    );

    final result = await arbiter.acquireForeground(bindingDigest: 'same-binding');

    expect(result.disposition, BackupAdmissionDisposition.acquired);
    expect(result.lease?.runToken, 'replacement');
    expect(leases.recoverExactCalls, 1);
    expect(leases.releaseCalls, 1);
    expect(registry.cancelAndDrainCalls, 0);
  });

  test('expired lease with exact active native task is renewed and adopted', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final leases = _Leases(existing: _lease('old', 'same', now.subtract(const Duration(minutes: 2))));
    final registry = _Registry()..snapshots = [_active('old', 'same')];
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: registry,
      clock: () => now,
      tokenFactory: () => 'new',
    );

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(result.disposition, BackupAdmissionDisposition.adoptedBackground);
    expect(leases.acquireCalls, 0);
  });

  test('expired closing lease with its exact waiting task is adopted without renewal', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final expired = _lease('owned', 'same', now.subtract(const Duration(minutes: 2))).copyWith(
      state: BackupExecutionState.closing,
      outstandingClaims: {const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'owned-waiting')},
    );
    const task = BackupTaskSnapshot(
      taskId: 'owned-waiting',
      group: BackupTaskGroup.primary,
      status: BackupTaskStatus.waitingToRetry,
      metadata: BackupTaskMetadata.current(runToken: 'owned', bindingDigest: 'same', phase: BackupTaskPhase.primary),
    );
    final leases = _Leases(existing: expired);
    final registry = _Registry()..snapshots = [task];
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(result.disposition, BackupAdmissionDisposition.adoptedBackground);
    expect(result.lease?.state, BackupExecutionState.closing);
    expect(result.lease?.expiresAt, expired.expiresAt);
    expect(leases.existing?.expiresAt, expired.expiresAt);
    expect(leases.acquireCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('expired closing lease adopts and promotes its exact active enqueue claim', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'owned-enqueue');
    final expired = _lease(
      'owned',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, enqueueClaims: {claim});
    const task = BackupTaskSnapshot(
      taskId: 'owned-enqueue',
      group: BackupTaskGroup.primary,
      status: BackupTaskStatus.running,
      metadata: BackupTaskMetadata.current(runToken: 'owned', bindingDigest: 'same', phase: BackupTaskPhase.primary),
    );
    final leases = _Leases(existing: expired);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry()..snapshots = [task], clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(result.disposition, BackupAdmissionDisposition.adoptedBackground);
    expect(result.lease?.state, BackupExecutionState.closing);
    expect(result.lease?.expiresAt, expired.expiresAt);
    expect(result.lease?.enqueueClaims, isEmpty);
    expect(result.lease?.outstandingClaims, {claim});
    expect(leases.releaseCalls, 0);
  });

  test('durable background claim from another binding cannot be adopted', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'foreign-owner');
    final lease = _lease('owned', 'other-binding', now).copyWith(outstandingClaims: {claim});
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry(), clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(result.disposition, BackupAdmissionDisposition.awaitingExpiry);
    expect(leases.existing, lease);
    expect(leases.acquireCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('owned task without its durable lease is drained instead of adopted', () async {
    final registry = _Registry()..snapshots = [_active('orphan', 'same')];
    final leases = _Leases();
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, tokenFactory: () => 'foreground');

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(registry.cancelAndDrainCalls, 1);
    expect(result.disposition, BackupAdmissionDisposition.acquired);
  });

  test('T2 tasks with a T1 lease are drained even when the binding digest matches', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final registry = _Registry()..snapshots = [_active('task-token', 'same')];
    final leases = _Leases(existing: _lease('lease-token', 'same', now));
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(registry.cancelAndDrainCalls, 1);
    expect(result.disposition, BackupAdmissionDisposition.acquired);
  });

  test('post-acquire task race releases provisional lease and admits zero work', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final leases = _Leases();
    final registry = _Registry()
      ..snapshotSequence = [
        const [],
        [_active('background', 'same')],
      ];
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: registry,
      clock: () => now,
      tokenFactory: () => 'foreground',
    );

    final result = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(result.disposition, BackupAdmissionDisposition.ownerActive);
    expect(leases.releaseCalls, 1);
  });

  for (final scenario in ['mismatch', 'multi-token', 'legacy']) {
    test('$scenario tasks are cancelled and drained before a new admission', () async {
      final registry = _Registry();
      registry.snapshots = switch (scenario) {
        'mismatch' => [_active('background', 'other-binding')],
        'multi-token' => [_active('a', 'same'), _active('b', 'same', group: BackupTaskGroup.livePhoto)],
        _ => [
          const BackupTaskSnapshot(taskId: 'legacy', group: BackupTaskGroup.primary, status: BackupTaskStatus.enqueued),
        ],
      };
      final leases = _Leases();
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, tokenFactory: () => 'foreground');

      final result = await arbiter.acquireForeground(bindingDigest: 'same');

      expect(registry.cancelAndDrainCalls, 1);
      expect(result.disposition, BackupAdmissionDisposition.acquired);
    });
  }

  test('quiescence requires Q1, callback zero, microtask drain, Q2, and unchanged revision', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now);
    final leases = _Leases(existing: lease);
    final registry = _Registry()..snapshotSequence = [const [], const []];
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    expect(await arbiter.releaseWhenQuiescent(lease), isTrue);
    expect(registry.snapshotCalls, 2);
    expect(leases.releaseCalls, 1);
  });

  test('Q2 race or callback in flight retains lease', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now);
    final registry = _Registry()
      ..snapshotSequence = [
        const [],
        [_active('foreground', 'same')],
      ];
    final leases = _Leases(existing: lease.copyWith(callbacksInFlight: 1));
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    expect(await arbiter.releaseWhenQuiescent(leases.existing!), isFalse);
    expect(leases.releaseCalls, 0);
  });

  test('foreground heartbeat renews the exact lease and advances activity revision', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now);
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry(),
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final renewed = await arbiter.renewCurrent(runToken: 'foreground', bindingDigest: 'same');

    expect(renewed?.activityRevision, lease.activityRevision + 1);
    expect(renewed?.expiresAt, now.add(const Duration(minutes: 2)));
  });

  test('enqueue reservation blocks logout drain and preserves ownership until bounded timeout', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now).copyWith(
      enqueueClaims: {const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-enqueue')},
    );
    final leases = _Leases(existing: lease);
    final registry = _Registry();
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final drained = await arbiter.disableAndDrain(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      timeout: const Duration(milliseconds: 5),
    );

    expect(drained, isFalse);
    expect(registry.cancelAndDrainCalls, 0);
    expect(leases.existing?.state, BackupExecutionState.closing);
    expect(leases.existing?.enqueueClaims, lease.enqueueClaims);
    expect(leases.releaseCalls, 0);
  });

  test('expired callback orphan recovers after stable empty native snapshots', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('background', 'same', now.subtract(const Duration(minutes: 2))).copyWith(callbacksInFlight: 1);
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry(),
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final admission = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(admission.disposition, BackupAdmissionDisposition.acquired);
    expect(leases.acquireCalls, 1);
  });

  test('outstanding task count prevents quiescent release', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('background', 'same', now).copyWith(
      outstandingClaims: {const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-outstanding')},
    );
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry(), clock: () => now);

    expect(await arbiter.releaseWhenQuiescent(lease), isFalse);
    expect(leases.releaseCalls, 0);
  });

  test('suspended heartbeat cannot transfer an expired foreground activity claim', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now.subtract(const Duration(minutes: 2))).copyWith(
      foregroundActivityClaims: {
        ForegroundTransportClaim.legacy(activityId: 'opaque-transport', bindingDigest: 'same', nativeGeneration: 7),
      },
    );
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry(), clock: () => now);

    final admission = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(admission.disposition, BackupAdmissionDisposition.recoveryPending);
    expect(leases.acquireCalls, 0);
  });

  test('expired foreground claim transfers only after exact native fence and drain acknowledgement', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'opaque-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(foregroundActivityClaims: {claim});
    final leases = _Leases(existing: lease);
    final fence = _Fence(acknowledged: false);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry(),
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
      tokenFactory: () => 'replacement',
    );

    expect(
      (await arbiter.acquireForeground(bindingDigest: 'same')).disposition,
      BackupAdmissionDisposition.recoveryPending,
    );
    expect(leases.acquireCalls, 0);
    expect(leases.existing?.foregroundActivityClaims, {claim});

    fence.acknowledged = true;
    final admission = await arbiter.acquireForeground(bindingDigest: 'same');
    expect(admission.disposition, BackupAdmissionDisposition.acquired);
    expect(admission.lease?.runToken, 'replacement');
    expect(fence.claims, [claim, claim]);
  });

  test('closing lease heartbeat is rejected so the transport cancellation path runs', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now).copyWith(state: BackupExecutionState.closing);
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry(), clock: () => now);

    expect(await arbiter.renewCurrent(runToken: lease.runToken, bindingDigest: lease.bindingDigest), isNull);
    expect(leases.existing, lease);
  });

  test('expired durable claims are adopted before recovery so the owner mailbox can be replayed', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final orphan = _lease('orphan', 'same', now.subtract(const Duration(minutes: 2))).copyWith(
      outstandingClaims: {const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-orphan')},
    );
    final registry = _Registry()..snapshotSequence = [const [], const [], const [], const []];
    final leases = _Leases(existing: orphan);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: registry,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
      tokenFactory: () => 'replacement',
    );

    final admission = await arbiter.acquireForeground(bindingDigest: 'same');

    expect(admission.disposition, BackupAdmissionDisposition.adoptedBackground);
    expect(admission.lease, orphan);
    expect(leases.recoverExactCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('concurrent disable callers share one closing and drain operation', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('foreground', 'same', now);
    final leases = _Leases(existing: lease);
    final registry = _Registry();
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final results = await Future.wait([
      arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest),
      arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest),
    ]);

    expect(results, [isTrue, isTrue]);
    expect(registry.cancelAndDrainCalls, 1);
  });

  test('disable recovers an expired same-owner closing lease after Q1, yield, Q2, and exact fences', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final foregroundClaim = ForegroundTransportClaim.legacy(
      activityId: 'foreground-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease('foreground', 'same', now.subtract(const Duration(minutes: 2))).copyWith(
      state: BackupExecutionState.closing,
      callbacksInFlight: 1,
      outstandingClaims: {const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'orphan')},
      foregroundActivityClaims: {foregroundClaim},
    );
    final events = <String>[];
    final leases = _Leases(existing: lease, events: events);
    final registry = _Registry(events: events)..snapshotSequence = [const [], const [], const [], const []];
    final fence = _Fence(acknowledged: true, events: events);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: registry,
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isTrue);
    expect(fence.claims, [foregroundClaim]);
    expect(leases.recoverExactCalls, 1);
    expect(leases.releasedLeases.single.hasDurableActivity, isFalse);
    expect(events.take(2), ['snapshot-1', 'snapshot-2']);
    expect(leases.existing, isNull);
  });

  test('disable keeps expired closing lease and claims when an exact foreground fence is rejected', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'rejected-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, callbacksInFlight: 1, foregroundActivityClaims: {claim});
    final leases = _Leases(existing: lease);
    final fence = _Fence(acknowledged: false);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isFalse);
    expect(fence.claims, [claim]);
    expect(leases.existing?.foregroundActivityClaims, {claim});
    expect(leases.existing?.callbacksInFlight, 1);
    expect(leases.recoverExactCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('expired recovery fences every exact foreground claim before one full-snapshot CAS', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final firstClaim = ForegroundTransportClaim.legacy(
      activityId: 'first-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final secondClaim = ForegroundTransportClaim.legacy(
      activityId: 'second-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {firstClaim, secondClaim});
    final leases = _Leases(existing: lease);
    final fence = _Fence(acknowledged: true);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const [], const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isTrue);
    expect(fence.claims, [firstClaim, secondClaim]);
    expect(leases.recoverExactCalls, 1);
    expect(leases.existing, isNull);
  });

  test('disable never orphan-recovers a non-expired closing lease', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'live-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now,
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {claim});
    final leases = _Leases(existing: lease);
    final fence = _Fence(acknowledged: true);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry(),
      foregroundFence: fence,
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      timeout: const Duration(milliseconds: 1),
    );

    expect(drained, isFalse);
    expect(fence.claims, isEmpty);
    expect(leases.recoverExactCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('disable does not classify a newly closing expired lease as an orphan', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final lease = _lease('foreground', 'same', now.subtract(const Duration(minutes: 2)));
    final leases = _Leases(existing: lease);
    final registry = _Registry();
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isTrue);
    expect(registry.cancelAndDrainCalls, 1);
    expect(leases.recoverExactCalls, 0);
  });

  test('disable fails closed when native work appears in Q2', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, callbacksInFlight: 1);
    final registry = _Registry()
      ..snapshotSequence = [
        const [],
        [_active('foreground', 'same')],
      ];
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry, clock: () => now);

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isFalse);
    expect(registry.snapshotCalls, 2);
    expect(leases.existing, lease);
    expect(leases.recoverExactCalls, 0);
    expect(leases.releaseCalls, 0);
  });

  test('expired recovery never clears a callback that is live in the current Dart isolate', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    const callbackClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'live-callback');
    final lease = _lease('foreground', 'same', now.subtract(const Duration(minutes: 2))).copyWith(
      state: BackupExecutionState.closing,
      callbacksInFlight: 1,
      outstandingClaims: {callbackClaim},
      callbackClaims: {callbackClaim},
    );
    final leases = _Leases(existing: lease);
    final callbackFence = BackupCallbackFence();
    final permit = callbackFence.tryBegin(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
    expect(permit, isNotNull);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      callbackFence: callbackFence,
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      timeout: const Duration(milliseconds: 1),
    );

    expect(drained, isFalse);
    expect(leases.existing?.callbacksInFlight, 1);
    expect(leases.existing?.callbackClaims, {callbackClaim});
    expect(leases.releaseCalls, 0);
    callbackFence.end(permit!);
  });

  test('expired callback recovery fails closed without a same-isolate callback fence capability', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    const callbackClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'unsupported-callback');
    final lease = _lease('background', 'same', now.subtract(const Duration(minutes: 2))).copyWith(
      state: BackupExecutionState.closing,
      callbacksInFlight: 1,
      outstandingClaims: {callbackClaim},
      callbackClaims: {callbackClaim},
    );
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isFalse);
    expect(leases.existing, lease);
    expect(leases.recoverExactCalls, 0);
  });

  test('callback activity appearing while a foreground fence awaits makes recovery fail closed', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    final foregroundClaim = ForegroundTransportClaim.legacy(
      activityId: 'foreground-transport',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    const callbackClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'new-callback');
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {foregroundClaim});
    final leases = _Leases(existing: lease);
    final fence = _Fence(
      acknowledged: true,
      onFence: (_) {
        final current = leases.existing!;
        leases.existing = current.copyWith(
          callbacksInFlight: 1,
          callbackClaims: {callbackClaim},
          activityRevision: current.activityRevision + 1,
        );
      },
    );
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final drained = await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);

    expect(drained, isFalse);
    expect(leases.existing?.callbacksInFlight, 1);
    expect(leases.existing?.callbackClaims, {callbackClaim});
    expect(leases.releaseCalls, 0);
  });

  test('new foreground claims carry the root native transport incarnation', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final lease = _lease('foreground', 'same', now);
    final leases = _Leases(existing: lease);
    final fence = _Fence(acknowledged: true);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry(), foregroundFence: fence);

    final claim = await arbiter.beginForegroundActivity(lease, expectedNativeGeneration: 7);

    expect(claim?.transportIncarnation, 'current-process');
    expect(claim?.claimSchemaVersion, ForegroundTransportClaim.currentSchemaVersion);
    expect(leases.existing?.foregroundActivityClaims, {claim});
  });

  test('native identity generation mismatch rejects a foreground claim before persistence', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final lease = _lease('foreground', 'same', now);
    final leases = _Leases(existing: lease);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry(),
      foregroundFence: _Fence(acknowledged: true),
    );

    expect(await arbiter.beginForegroundActivity(lease, expectedNativeGeneration: 8), isNull);
    expect(leases.existing, lease);
  });

  test('foreground admission rolls back its durable claim when authority blocks during the claim CAS', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final lease = _lease('foreground', 'same', now);
    final fence = _Fence(acknowledged: true);
    final leases = _Leases(existing: lease, afterBeginForeground: () => fence.identityCurrent = false);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: _Registry(), foregroundFence: fence);

    expect(await arbiter.beginForegroundActivity(lease, expectedNativeGeneration: 7), isNull);
    expect(leases.existing?.foregroundActivityClaims, isEmpty);
  });

  for (final scenario in [
    (name: 'binding mismatch without proof', incarnation: null),
    (name: 'transport incarnation ABA', incarnation: 'previous-process'),
  ]) {
    test('${scenario.name} preserves the expired closing lease', () async {
      final now = DateTime.utc(2026, 9, 2, 18);
      final claim = scenario.incarnation == null
          ? ForegroundTransportClaim.legacy(
              activityId: 'stale-foreground',
              bindingDigest: 'session-a-binding',
              nativeGeneration: 7,
            )
          : ForegroundTransportClaim.current(
              activityId: 'stale-foreground',
              bindingDigest: 'session-a-binding',
              nativeGeneration: 7,
              transportIncarnation: scenario.incarnation!,
            );
      final lease = _lease(
        'session-a',
        'session-a-binding',
        now.subtract(const Duration(minutes: 2)),
      ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {claim});
      final leases = _Leases(existing: lease);
      final fence = _Fence(acknowledged: false);
      final arbiter = BackupExecutionArbiter(
        leases: leases,
        tasks: _Registry()..snapshotSequence = [const [], const []],
        foregroundFence: fence,
        callbackFence: BackupCallbackFence(),
        clock: () => now,
      );

      expect(await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest), isFalse);
      expect(leases.existing, lease);
      expect(leases.recoverExactCalls, 0);
    });
  }

  test('native retirement timeout preserves every durable claim', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'timed-out-claim',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {claim});
    final leases = _Leases(existing: lease);
    final fence = _Fence(
      acknowledged: false,
      retirementAction: (_) async => throw TimeoutException('native retirement'),
    );
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    await expectLater(
      arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest),
      throwsA(isA<TimeoutException>()),
    );
    expect(leases.existing, lease);
    expect(leases.recoverExactCalls, 0);
  });

  test('full-snapshot CAS race after positive native proof preserves the raced lease', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'cas-race-claim',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {claim});
    var raced = false;
    final leases = _Leases(
      existing: lease,
      beforeRecover: (leases) {
        if (raced) return;
        raced = true;
        final current = leases.existing!;
        leases.existing = current.copyWith(activityRevision: current.activityRevision + 1);
      },
    );
    final fence = _Fence(acknowledged: true);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    expect(await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest), isFalse);
    expect(leases.existing?.activityRevision, lease.activityRevision + 1);
    expect(leases.existing?.foregroundActivityClaims, {claim});
    expect(leases.releaseCalls, 0);

    expect(await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest), isTrue);
    expect(leases.existing, isNull);
    expect(fence.retirementCalls, 2);
  });

  test('new foreground admission is rejected while the native retirement barrier is open', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'persisted-claim',
      bindingDigest: 'same',
      nativeGeneration: 7,
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {claim});
    final leases = _Leases(existing: lease);
    final barrierStarted = Completer<void>();
    final releaseBarrier = Completer<void>();
    final fence = _Fence(
      acknowledged: true,
      retirementAction: (_) async {
        barrierStarted.complete();
        await releaseBarrier.future;
        return ForegroundTransportRetirement.retired;
      },
    );
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    final draining = arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
    await barrierStarted.future;
    expect(await arbiter.beginForegroundActivity(lease, expectedNativeGeneration: 7), isNull);
    releaseBarrier.complete();
    expect(await draining, isTrue);
  });

  test('multi-claim retirement is all-or-nothing and runs one native barrier', () async {
    final now = DateTime.utc(2026, 9, 2, 18);
    final legacy = ForegroundTransportClaim.legacy(activityId: 'legacy', bindingDigest: 'same', nativeGeneration: 6);
    final current = ForegroundTransportClaim.current(
      activityId: 'current',
      bindingDigest: 'same',
      nativeGeneration: 7,
      transportIncarnation: 'current-process',
    );
    final lease = _lease(
      'foreground',
      'same',
      now.subtract(const Duration(minutes: 2)),
    ).copyWith(state: BackupExecutionState.closing, foregroundActivityClaims: {legacy, current});
    final leases = _Leases(existing: lease);
    final fence = _Fence(acknowledged: false);
    final arbiter = BackupExecutionArbiter(
      leases: leases,
      tasks: _Registry()..snapshotSequence = [const [], const []],
      foregroundFence: fence,
      callbackFence: BackupCallbackFence(),
      clock: () => now,
    );

    expect(await arbiter.disableAndDrain(runToken: lease.runToken, bindingDigest: lease.bindingDigest), isFalse);
    expect(fence.retirementCalls, 1);
    expect(fence.claims.toSet(), {legacy, current});
    expect(leases.existing?.foregroundActivityClaims, {legacy, current});
    expect(leases.recoverExactCalls, 0);
  });
}

BackupTaskSnapshot _active(String token, String binding, {BackupTaskGroup group = BackupTaskGroup.primary}) =>
    BackupTaskSnapshot(
      taskId: 'opaque-$token-${group.name}',
      group: group,
      status: BackupTaskStatus.running,
      metadata: BackupTaskMetadata.current(runToken: token, bindingDigest: binding, phase: BackupTaskPhase.primary),
    );

BackupExecutionLease _lease(String token, String binding, DateTime now) => BackupExecutionLease(
  mode: BackupExecutionMode.background,
  runToken: token,
  bindingDigest: binding,
  expiresAt: now.add(const Duration(minutes: 1)),
  activityRevision: 0,
  callbacksInFlight: 0,
);

final class _Leases implements BackupExecutionLeasePort {
  _Leases({this.existing, List<String>? events, this.beforeRecover, this.afterBeginForeground}) : events = events ?? [];
  BackupExecutionLease? existing;
  final List<String> events;
  final void Function(_Leases leases)? beforeRecover;
  final void Function()? afterBeginForeground;
  int acquireCalls = 0;
  int releaseCalls = 0;
  int recoverExactCalls = 0;
  final List<BackupExecutionLease> releasedLeases = [];

  @override
  Future<bool> acquire(BackupExecutionLease candidate, DateTime now) async {
    acquireCalls++;
    if (existing != null && !existing!.isExpiredAt(now)) return false;
    existing = candidate;
    return true;
  }

  @override
  Future<BackupExecutionLease?> beginCallback(BackupExecutionLease expected) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> beginCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    String? operationIncarnation,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> endCallback(BackupExecutionLease expected) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> endCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> markEnqueued(BackupExecutionLease expected) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> markEnqueuedForTask({required String runToken, required String bindingDigest}) =>
      throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> beginEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> beginEnqueueUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
    String? operationIncarnation,
  }) => throw UnimplementedError();

  @override
  Future<bool> allowForegroundCandidateUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required String candidateKey,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> confirmEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> abortEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> consumeTerminalForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> markReconciliationPendingForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> completeReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> quarantineReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
    required BackupReconciliationQuarantineCode code,
  }) => throw UnimplementedError();

  @override
  Future<Set<BackupReconciliationQuarantineEntry>> readReconciliationQuarantine() => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> reconcileTaskClaimsForOwner({
    required String runToken,
    required String bindingDigest,
    required Set<BackupTaskClaim> activeClaims,
  }) async {
    final current = existing;
    if (current == null || current.runToken != runToken || current.bindingDigest != bindingDigest) return null;
    final outstanding = current.state == BackupExecutionState.closing
        ? {...current.outstandingClaims, ...current.enqueueClaims}.intersection(activeClaims)
        : activeClaims;
    existing = current.copyWith(
      outstandingClaims: outstanding,
      enqueueClaims: current.enqueueClaims.difference(activeClaims),
      activityRevision: current.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> recoverExpiredClosingExact({
    required BackupExecutionLease expected,
    required Set<BackupTaskClaim> activeClaims,
  }) async {
    recoverExactCalls++;
    beforeRecover?.call(this);
    final current = existing;
    if (current != expected || expected.state != BackupExecutionState.closing) return null;
    existing = expected.copyWith(
      outstandingClaims: activeClaims,
      enqueueClaims: const {},
      terminalTombstones: const {},
      callbacksInFlight: 0,
      callbackClaims: const {},
      foregroundActivityClaims: const {},
      activityRevision: expected.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> releaseOrphanedCallbackForTaskExact({
    required BackupExecutionLease expected,
    required BackupTaskClaim claim,
  }) async => null;

  @override
  Future<BackupExecutionLease?> beginClosingForOwner({required String runToken, required String bindingDigest}) async {
    final current = existing;
    if (current == null || current.runToken != runToken || current.bindingDigest != bindingDigest) return null;
    if (current.state == BackupExecutionState.closing) return current;
    existing = current.copyWith(state: BackupExecutionState.closing, activityRevision: current.activityRevision + 1);
    return existing;
  }

  @override
  Future<BackupExecutionLease?> beginForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  }) async {
    final current = existing;
    if (current == null || current.runToken != runToken || current.bindingDigest != bindingDigest) return null;
    if (current.state == BackupExecutionState.closing) return null;
    existing = current.copyWith(
      foregroundActivityClaims: {...current.foregroundActivityClaims, claim},
      activityRevision: current.activityRevision + 1,
    );
    afterBeginForeground?.call();
    return existing;
  }

  @override
  Future<BackupExecutionLease?> endForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  }) async {
    final current = existing;
    if (current == null || current.runToken != runToken || current.bindingDigest != bindingDigest) return null;
    existing = current.copyWith(
      foregroundActivityClaims: {...current.foregroundActivityClaims}..remove(claim),
      activityRevision: current.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> read() async => existing;

  @override
  Future<bool> releaseExact(BackupExecutionLease expected) async {
    releaseCalls++;
    releasedLeases.add(expected);
    if (existing != expected) return false;
    existing = null;
    return true;
  }

  @override
  Future<bool> replaceExact({required BackupExecutionLease expected, required BackupExecutionLease replacement}) async {
    if (existing != expected) return false;
    existing = replacement;
    return true;
  }
}

typedef _RetirementAction = Future<ForegroundTransportRetirement> Function(Set<ForegroundTransportClaim> claims);

final class _Fence implements ForegroundTransportFencePort {
  _Fence({required this.acknowledged, List<String>? events, this.onFence, this.retirementAction})
    : events = events ?? [];

  bool acknowledged;
  final List<String> events;
  final void Function(ForegroundTransportClaim claim)? onFence;
  final _RetirementAction? retirementAction;
  final ForegroundTransportIdentity identity = const ForegroundTransportIdentity(
    incarnation: 'current-process',
    generation: 7,
  );
  final List<ForegroundTransportClaim> claims = [];
  int retirementCalls = 0;
  bool identityCurrent = true;

  @override
  Future<ForegroundTransportIdentity?> captureIdentity() async => identity;

  @override
  bool isIdentityCurrent(ForegroundTransportIdentity expected, {required String bindingDigest}) =>
      identityCurrent && expected == identity && bindingDigest == 'same';

  @override
  Future<ForegroundTransportRetirement> retireClaims(
    Set<ForegroundTransportClaim> requestedClaims, {
    required Duration timeout,
  }) async {
    retirementCalls++;
    claims.addAll(requestedClaims);
    for (final claim in requestedClaims) {
      events.add('fence-${claim.activityId}');
      onFence?.call(claim);
    }
    if (retirementAction case final action?) return action(requestedClaims);
    return acknowledged ? ForegroundTransportRetirement.retired : ForegroundTransportRetirement.temporarilyUnproven;
  }
}

final class _Registry implements BackupTaskRegistryPort {
  _Registry({Completer<void>? ready, List<String>? events})
    : _ready = ready ?? (Completer<void>()..complete()),
      events = events ?? [];

  final Completer<void> _ready;
  final List<String> events;
  List<BackupTaskSnapshot> snapshots = [];
  List<List<BackupTaskSnapshot>> snapshotSequence = [];
  int snapshotCalls = 0;
  int cancelAndDrainCalls = 0;
  Set<BackupTaskGroup> requestedGroups = {};

  @override
  Future<void> get ready => _ready.future;

  void completeReady() => _ready.complete();

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async {
    snapshotCalls++;
    events.add('snapshot-$snapshotCalls');
    requestedGroups = groups;
    if (snapshotSequence.isNotEmpty) return snapshotSequence.removeAt(0);
    return snapshots;
  }

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) async {
    cancelAndDrainCalls++;
    snapshots = [];
    return true;
  }
}
