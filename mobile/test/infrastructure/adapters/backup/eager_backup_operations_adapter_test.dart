import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/eager_backup_operations_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockLeasePort extends Mock implements BackupExecutionLeasePort {}

class _MockTaskRegistry extends Mock implements BackupTaskRegistryPort {}

class _MockBackups extends Mock implements DriftBackupRepository {}

class _MockSynchronization extends Mock implements BackgroundSyncManager {}

class _MockUploads extends Mock implements ForegroundUploadService {}

class _MockBindings extends Mock implements BackupRunBindingSourcePort {}

final class _BackgroundUploads implements EagerBackgroundUploadPort {
  _BackgroundUploads({
    this.snapshot = const EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 1, pausedCount: 0),
    this.resumedEvent = const EagerBackgroundUploadEvent(
      activity: BackupUploadActivity(kind: BackupUploadActivityKind.success, localAssetId: 'asset-a'),
      terminal: EagerBackgroundUploadTerminal.succeeded,
      remainingActiveCount: 0,
    ),
    this.beforeSnapshotReturns,
    this.beforeResumeReturns,
  });

  final StreamController<EagerBackgroundUploadEvent> controller = StreamController.broadcast(sync: true);
  final EagerBackgroundUploadSnapshot snapshot;
  final EagerBackgroundUploadEvent? resumedEvent;
  final Future<void> Function()? beforeSnapshotReturns;
  final Future<void> Function()? beforeResumeReturns;
  int resumeCalls = 0;
  final List<EagerBackgroundUploadOwner> observedOwners = [];

  @override
  Stream<EagerBackgroundUploadEvent> eventsFor(EagerBackgroundUploadOwner owner) {
    observedOwners.add(owner);
    return controller.stream;
  }

  @override
  Future<EagerBackgroundUploadSnapshot> readSnapshot(EagerBackgroundUploadOwner owner) async {
    await beforeSnapshotReturns?.call();
    return snapshot;
  }

  @override
  Future<EagerBackgroundResumeDisposition> resumeOwned(EagerBackgroundUploadOwner owner) async {
    resumeCalls++;
    final event = resumedEvent;
    if (event != null) controller.add(event);
    await beforeResumeReturns?.call();
    return EagerBackgroundResumeDisposition.observing;
  }
}

final class _Projection implements EagerBackupActivityProjectionPort {
  final List<BackupUploadActivity> activities = [];
  final List<EagerBackgroundUploadSnapshot> snapshots = [];

  @override
  void presentActivity(BackupUploadActivity activity) => activities.add(activity);

  @override
  void presentBackgroundSnapshot(EagerBackgroundUploadSnapshot snapshot) => snapshots.add(snapshot);
}

final class _Diagnostics implements EagerBackupDiagnosticsPort {
  final List<EagerBackupDiagnosticEvent> events = [];

  @override
  void report(EagerBackupDiagnosticEvent event) => events.add(event);
}

final class _ForegroundFence implements ForegroundTransportFencePort {
  const _ForegroundFence();

  @override
  Future<ForegroundTransportIdentity?> captureIdentity() async =>
      const ForegroundTransportIdentity(incarnation: 'root-process', generation: 3);

  @override
  bool isIdentityCurrent(ForegroundTransportIdentity identity, {required String bindingDigest}) => true;

  @override
  Future<ForegroundTransportRetirement> retireClaims(
    Set<ForegroundTransportClaim> claims, {
    required Duration timeout,
  }) async => ForegroundTransportRetirement.retired;
}

final class _MissingForegroundFence implements ForegroundTransportFencePort {
  const _MissingForegroundFence();

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

void main() {
  setUpAll(() {
    registerFallbackValue(_lease('fallback'));
    registerFallbackValue(
      ForegroundTransportClaim.legacy(activityId: 'fallback', bindingDigest: 'fallback', nativeGeneration: 0),
    );
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());
  });

  test('foreground adapter forwards progress, iCloud, success, and error through one projection', () async {
    final binding = _binding();
    final admission = _foregroundAdmission();
    final uploads = _MockUploads();
    final bindings = _MockBindings();
    final projection = _Projection();
    when(() => bindings.isCurrent(binding)).thenReturn(true);
    when(
      () => uploads.uploadCandidates(
        binding.userId,
        any(),
        binding: binding,
        executionLease: any(named: 'executionLease'),
        isBindingCurrent: any(named: 'isBindingCurrent'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      final callbacks = invocation.namedArguments[#callbacks] as UploadCallbacks;
      callbacks.onProgress?.call('asset-a', 'asset.mov', 25, 100);
      callbacks.onICloudProgress?.call('asset-a', 0.5);
      callbacks.onSuccess?.call('asset-a', 'remote-a');
      callbacks.onError?.call('asset-b', 'upload failed');
      return const ForegroundUploadResult.completed();
    });
    final adapter = EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: _MockBackups(),
      synchronization: _MockSynchronization(),
      uploads: uploads,
      arbiter: admission.arbiter,
      bindings: bindings,
      activityProjection: projection,
      heartbeatInterval: const Duration(hours: 1),
    );

    await expectLater(
      adapter.upload(binding, EagerBackupCancellation()),
      throwsA(isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.transient)),
    );
    expect(projection.activities.map((activity) => activity.kind), [
      BackupUploadActivityKind.progress,
      BackupUploadActivityKind.iCloudProgress,
      BackupUploadActivityKind.success,
      BackupUploadActivityKind.error,
    ]);
  });

  test('foreground callbacks after a binding switch cannot mutate the projection', () async {
    final binding = _binding();
    final admission = _foregroundAdmission();
    final uploads = _MockUploads();
    final bindings = _MockBindings();
    final projection = _Projection();
    final uploadStarted = Completer<void>();
    final finishUpload = Completer<void>();
    late UploadCallbacks callbacks;
    var bindingCurrent = true;
    when(() => bindings.isCurrent(binding)).thenAnswer((_) => bindingCurrent);
    when(
      () => uploads.uploadCandidates(
        binding.userId,
        any(),
        binding: binding,
        executionLease: any(named: 'executionLease'),
        isBindingCurrent: any(named: 'isBindingCurrent'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((invocation) async {
      callbacks = invocation.namedArguments[#callbacks] as UploadCallbacks;
      uploadStarted.complete();
      await finishUpload.future;
      return const ForegroundUploadResult.completed();
    });
    final adapter = EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: _MockBackups(),
      synchronization: _MockSynchronization(),
      uploads: uploads,
      arbiter: admission.arbiter,
      bindings: bindings,
      activityProjection: projection,
      heartbeatInterval: const Duration(hours: 1),
    );

    final operation = adapter.upload(binding, EagerBackupCancellation());
    await uploadStarted.future;
    bindingCurrent = false;
    callbacks.onProgress?.call('asset-a', 'video.mov', 25, 100);
    callbacks.onICloudProgress?.call('asset-a', 0.25);
    callbacks.onSuccess?.call('asset-a', 'remote-a');
    callbacks.onError?.call('asset-a', 'late failure');
    finishUpload.complete();

    await expectLater(
      operation,
      throwsA(isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.staleContext)),
    );
    expect(projection.activities, isEmpty);
  });

  test('foreground transport identity failure is exposed as binding stale', () async {
    final binding = _binding();
    final admission = _foregroundAdmission(foregroundFence: const _MissingForegroundFence());
    final bindings = _MockBindings();
    when(() => bindings.isCurrent(binding)).thenReturn(true);
    final adapter = EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: _MockBackups(),
      synchronization: _MockSynchronization(),
      uploads: _MockUploads(),
      arbiter: admission.arbiter,
      bindings: bindings,
    );

    await expectLater(
      adapter.upload(binding, EagerBackupCancellation()),
      throwsA(isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.bindingStale)),
    );
  });

  test('matching waiting background owner resumes once without foreground acquisition or release', () async {
    final fixture = _adoptedFixture();
    addTearDown(fixture.background.controller.close);

    expect(
      await fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      EagerBackupUploadOutcome.completed,
    );
    expect(fixture.background.resumeCalls, 1);
    expect(fixture.projection.snapshots.map((snapshot) => snapshot.activeCount), [1, 0]);
    expect(fixture.projection.activities.map((event) => event.kind), [BackupUploadActivityKind.success]);
    expect(fixture.diagnostics.events.single.admissionDisposition, EagerBackupAdmissionDisposition.backgroundAdopted);
    expect(fixture.diagnostics.events.single.activeClaims, 1);
    verifyNever(
      () => fixture.uploads.uploadCandidates(
        any(),
        any(),
        binding: any(named: 'binding'),
        executionLease: any(named: 'executionLease'),
        isBindingCurrent: any(named: 'isBindingCurrent'),
        callbacks: any(named: 'callbacks'),
      ),
    );
    verifyNever(() => fixture.leases.releaseExact(any()));
  });

  test('adopted owner resumes once when relaunch snapshot races to empty', () async {
    final fixture = _adoptedFixture(
      snapshot: const EagerBackgroundUploadSnapshot(activeCount: 0, waitingToRetryCount: 0, pausedCount: 0),
    );
    addTearDown(fixture.background.controller.close);

    expect(
      await fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      EagerBackupUploadOutcome.completed,
    );
    expect(fixture.background.resumeCalls, 1);
    verifyNever(
      () => fixture.uploads.uploadCandidates(
        any(),
        any(),
        binding: any(named: 'binding'),
        executionLease: any(named: 'executionLease'),
        isBindingCurrent: any(named: 'isBindingCurrent'),
        callbacks: any(named: 'callbacks'),
      ),
    );
    verifyNever(() => fixture.leases.releaseExact(any()));
  });

  test('empty adopted snapshot without a terminal cannot silently complete', () async {
    final fixture = _adoptedFixture(
      snapshot: const EagerBackgroundUploadSnapshot(activeCount: 0, waitingToRetryCount: 0, pausedCount: 0),
      resumedEvent: null,
      backgroundWatchdog: const Duration(milliseconds: 1),
    );
    addTearDown(fixture.background.controller.close);

    await expectLater(
      fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      throwsA(
        isA<EagerBackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          EagerBackupFailureKind.backgroundOwnerActive,
        ),
      ),
    );
    expect(fixture.background.resumeCalls, 1);
    verifyNever(() => fixture.leases.releaseExact(any()));
  });

  test('terminal completed before subscription is resolved by the exact owner snapshot', () async {
    final fixture = _adoptedFixture(
      snapshot: const EagerBackgroundUploadSnapshot(
        activeCount: 0,
        waitingToRetryCount: 0,
        pausedCount: 0,
        ownerState: EagerBackgroundOwnerState.completed,
      ),
      resumedEvent: null,
    );
    addTearDown(fixture.background.controller.close);

    expect(
      await fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      EagerBackupUploadOutcome.completed,
    );
    expect(fixture.background.resumeCalls, 0);
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('session change while reading owner snapshot prevents resume and removes listener', () async {
    var bindingCurrent = true;
    final fixture = _adoptedFixture(
      resumedEvent: null,
      bindingIsCurrent: () => bindingCurrent,
      beforeSnapshotReturns: () async => bindingCurrent = false,
    );
    addTearDown(fixture.background.controller.close);

    await expectLater(
      fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      throwsA(isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.bindingStale)),
    );
    expect(fixture.background.resumeCalls, 0);
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('session change during scoped resume fails closed and removes listener', () async {
    var bindingCurrent = true;
    final fixture = _adoptedFixture(
      resumedEvent: null,
      bindingIsCurrent: () => bindingCurrent,
      beforeResumeReturns: () async => bindingCurrent = false,
    );
    addTearDown(fixture.background.controller.close);

    await expectLater(
      fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      throwsA(isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.bindingStale)),
    );
    expect(fixture.background.resumeCalls, 1);
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('periodic owner progress renews inactivity watchdog until terminal', () async {
    final fixture = _adoptedFixture(resumedEvent: null, backgroundWatchdog: const Duration(milliseconds: 40));
    addTearDown(fixture.background.controller.close);
    final upload = fixture.adapter.upload(fixture.binding, EagerBackupCancellation());
    await pumpEventQueue();

    for (var index = 0; index < 3; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      fixture.background.controller.add(
        const EagerBackgroundUploadEvent(
          activity: BackupUploadActivity(
            kind: BackupUploadActivityKind.progress,
            localAssetId: 'asset-a',
            progress: 0.5,
          ),
        ),
      );
    }
    fixture.background.controller.add(
      const EagerBackgroundUploadEvent(
        activity: BackupUploadActivity(kind: BackupUploadActivityKind.success, localAssetId: 'asset-a'),
        terminal: EagerBackgroundUploadTerminal.succeeded,
        remainingActiveCount: 0,
      ),
    );

    expect(await upload, EagerBackupUploadOutcome.completed);
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('periodic owner status renews inactivity watchdog until terminal', () async {
    final fixture = _adoptedFixture(resumedEvent: null, backgroundWatchdog: const Duration(milliseconds: 40));
    addTearDown(fixture.background.controller.close);
    final upload = fixture.adapter.upload(fixture.binding, EagerBackupCancellation());
    await pumpEventQueue();

    for (var index = 0; index < 3; index++) {
      await Future<void>.delayed(const Duration(milliseconds: 25));
      fixture.background.controller.add(
        const EagerBackgroundUploadEvent(
          activity: BackupUploadActivity(kind: BackupUploadActivityKind.status, localAssetId: 'asset-a'),
        ),
      );
    }
    fixture.background.controller.add(
      const EagerBackgroundUploadEvent(
        activity: BackupUploadActivity(kind: BackupUploadActivityKind.success, localAssetId: 'asset-a'),
        terminal: EagerBackgroundUploadTerminal.succeeded,
        remainingActiveCount: 0,
      ),
    );

    expect(await upload, EagerBackupUploadOutcome.completed);
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('snapshot timeout fails closed and removes the owner listener', () async {
    final never = Completer<void>();
    final fixture = _adoptedFixture(
      resumedEvent: null,
      backgroundWatchdog: const Duration(milliseconds: 5),
      beforeSnapshotReturns: () => never.future,
    );
    addTearDown(fixture.background.controller.close);

    await expectLater(
      fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      throwsA(
        isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.recoveryPending),
      ),
    );
    expect(fixture.background.resumeCalls, 0);
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('cancelling adopted observation removes the owner listener', () async {
    final cancellation = EagerBackupCancellation();
    final fixture = _adoptedFixture(resumedEvent: null, backgroundWatchdog: const Duration(seconds: 1));
    addTearDown(fixture.background.controller.close);
    final upload = fixture.adapter.upload(fixture.binding, cancellation);
    await pumpEventQueue();

    cancellation.cancel();

    await expectLater(
      upload,
      throwsA(
        isA<EagerBackupFailure>().having(
          (failure) => failure.kind,
          'kind',
          EagerBackupFailureKind.backgroundOwnerActive,
        ),
      ),
    );
    expect(fixture.background.controller.hasListener, isFalse);
  });

  test('adopted background failure is terminal even while another task remains', () async {
    final fixture = _adoptedFixture(
      resumedEvent: const EagerBackgroundUploadEvent(
        activity: BackupUploadActivity(kind: BackupUploadActivityKind.error, localAssetId: 'asset-a'),
        terminal: EagerBackgroundUploadTerminal.failed,
        remainingActiveCount: 1,
      ),
      backgroundWatchdog: const Duration(milliseconds: 1),
    );
    addTearDown(fixture.background.controller.close);

    await expectLater(
      fixture.adapter.upload(fixture.binding, EagerBackupCancellation()),
      throwsA(isA<EagerBackupFailure>().having((failure) => failure.kind, 'kind', EagerBackupFailureKind.transient)),
    );
    expect(fixture.background.resumeCalls, 1);
  });

  test('non-expired empty lease reaches eager coordinator as typed awaiting-expiry failure', () async {
    final binding = _binding();
    final lease = _lease(binding.digest);
    final leases = _MockLeasePort();
    final tasks = _MockTaskRegistry();
    final bindings = _MockBindings();

    when(() => tasks.ready).thenAnswer((_) async {});
    when(() => tasks.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => []);
    when(leases.read).thenAnswer((_) async => lease);
    when(() => bindings.isCurrent(binding)).thenReturn(true);
    final adapter = EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: _MockBackups(),
      synchronization: _MockSynchronization(),
      uploads: _MockUploads(),
      arbiter: BackupExecutionArbiter(leases: leases, tasks: tasks, clock: () => DateTime.utc(2026, 8, 12, 11)),
      bindings: bindings,
    );

    await expectLater(
      adapter.upload(binding, EagerBackupCancellation()),
      throwsA(
        isA<EagerBackupFailure>()
            .having((failure) => failure.kind, 'kind', EagerBackupFailureKind.awaitingLeaseExpiry)
            .having((failure) => failure.retryAt, 'retryAt', lease.expiresAt),
      ),
    );
    verifyNever(() => leases.acquire(any(), any()));
    verifyNever(() => leases.releaseExact(any()));
  });

  test('transport denial skips reconciliation and releases the lease exactly once', () async {
    final binding = _binding();
    final leases = _MockLeasePort();
    final tasks = _MockTaskRegistry();
    final backups = _MockBackups();
    final synchronization = _MockSynchronization();
    final uploads = _MockUploads();
    final bindings = _MockBindings();
    BackupExecutionLease? currentLease;

    when(() => tasks.ready).thenAnswer((_) async {});
    when(() => tasks.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => []);
    when(leases.read).thenAnswer((_) async => currentLease);
    when(() => leases.acquire(any(), any())).thenAnswer((invocation) async {
      currentLease = invocation.positionalArguments.first as BackupExecutionLease;
      return true;
    });
    when(
      () => leases.beginForegroundActivityForOwner(
        runToken: any(named: 'runToken'),
        bindingDigest: any(named: 'bindingDigest'),
        claim: any(named: 'claim'),
      ),
    ).thenAnswer((invocation) async {
      final claim = invocation.namedArguments[#claim] as ForegroundTransportClaim;
      currentLease = currentLease!.copyWith(foregroundActivityClaims: {claim});
      return currentLease;
    });
    when(
      () => leases.endForegroundActivityForOwner(
        runToken: any(named: 'runToken'),
        bindingDigest: any(named: 'bindingDigest'),
        claim: any(named: 'claim'),
      ),
    ).thenAnswer((_) async {
      currentLease = currentLease!.copyWith(foregroundActivityClaims: const {});
      return currentLease;
    });
    when(() => leases.releaseExact(any())).thenAnswer((_) async {
      currentLease = null;
      return true;
    });
    when(() => bindings.isCurrent(binding)).thenReturn(true);
    when(
      () => uploads.uploadCandidates(
        binding.userId,
        any(),
        binding: binding,
        executionLease: any(named: 'executionLease'),
        isBindingCurrent: any(named: 'isBindingCurrent'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer(
      (_) async => const ForegroundUploadResult.denied(
        ForegroundUploadGateDenial(
          stage: ForegroundUploadGateStage.preStorage,
          reason: ForegroundUploadGateReason.transportCursorChanged,
        ),
      ),
    );

    final adapter = EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: backups,
      synchronization: synchronization,
      uploads: uploads,
      arbiter: BackupExecutionArbiter(
        leases: leases,
        tasks: tasks,
        foregroundFence: const _ForegroundFence(),
        tokenFactory: () => 'run-token',
      ),
      bindings: bindings,
      heartbeatInterval: const Duration(hours: 1),
    );

    final outcome = await adapter.upload(binding, EagerBackupCancellation());

    expect(outcome, EagerBackupUploadOutcome.transportCursorChanged);
    verifyNever(() => synchronization.syncRemoteForBinding(binding));
    verify(() => leases.releaseExact(any())).called(1);
  });
}

({
  EagerBackupOperationsAdapter adapter,
  BackupRunBinding binding,
  _MockUploads uploads,
  _MockLeasePort leases,
  _BackgroundUploads background,
  _Projection projection,
  _Diagnostics diagnostics,
})
_adoptedFixture({
  EagerBackgroundUploadSnapshot snapshot = const EagerBackgroundUploadSnapshot(
    activeCount: 1,
    waitingToRetryCount: 1,
    pausedCount: 0,
  ),
  EagerBackgroundUploadEvent? resumedEvent = const EagerBackgroundUploadEvent(
    activity: BackupUploadActivity(kind: BackupUploadActivityKind.success, localAssetId: 'asset-a'),
    terminal: EagerBackgroundUploadTerminal.succeeded,
    remainingActiveCount: 0,
  ),
  Duration backgroundWatchdog = const Duration(seconds: 1),
  Future<void> Function()? beforeSnapshotReturns,
  Future<void> Function()? beforeResumeReturns,
  bool Function()? bindingIsCurrent,
}) {
  final binding = _binding();
  final lease = _lease(binding.digest).copyWith(mode: BackupExecutionMode.background);
  final leases = _MockLeasePort();
  final tasks = _MockTaskRegistry();
  final uploads = _MockUploads();
  final bindings = _MockBindings();
  final background = _BackgroundUploads(
    snapshot: snapshot,
    resumedEvent: resumedEvent,
    beforeSnapshotReturns: beforeSnapshotReturns,
    beforeResumeReturns: beforeResumeReturns,
  );
  final projection = _Projection();
  final diagnostics = _Diagnostics();
  final task = BackupTaskSnapshot(
    taskId: 'owned-task',
    group: BackupTaskGroup.primary,
    status: BackupTaskStatus.waitingToRetry,
    metadata: BackupTaskMetadata.current(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      phase: BackupTaskPhase.primary,
    ),
  );

  when(() => tasks.ready).thenAnswer((_) async {});
  when(() => tasks.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => [task]);
  when(leases.read).thenAnswer((_) async => lease);
  when(
    () => leases.reconcileTaskClaimsForOwner(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      activeClaims: any(named: 'activeClaims'),
    ),
  ).thenAnswer(
    (_) async => lease.copyWith(
      outstandingClaims: {const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'owned-task')},
    ),
  );
  when(() => bindings.isCurrent(binding)).thenAnswer((_) => bindingIsCurrent?.call() ?? true);

  return (
    adapter: EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: _MockBackups(),
      synchronization: _MockSynchronization(),
      uploads: uploads,
      arbiter: BackupExecutionArbiter(leases: leases, tasks: tasks, clock: () => DateTime.utc(2026, 8, 12, 11)),
      bindings: bindings,
      backgroundUploads: background,
      activityProjection: projection,
      diagnostics: diagnostics,
      backgroundWatchdog: backgroundWatchdog,
    ),
    binding: binding,
    uploads: uploads,
    leases: leases,
    background: background,
    projection: projection,
    diagnostics: diagnostics,
  );
}

({BackupExecutionArbiter arbiter, _MockLeasePort leases}) _foregroundAdmission({
  ForegroundTransportFencePort foregroundFence = const _ForegroundFence(),
}) {
  final leases = _MockLeasePort();
  final tasks = _MockTaskRegistry();
  BackupExecutionLease? currentLease;
  when(() => tasks.ready).thenAnswer((_) async {});
  when(() => tasks.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => []);
  when(leases.read).thenAnswer((_) async => currentLease);
  when(() => leases.acquire(any(), any())).thenAnswer((invocation) async {
    currentLease = invocation.positionalArguments.first as BackupExecutionLease;
    return true;
  });
  when(
    () => leases.beginForegroundActivityForOwner(
      runToken: any(named: 'runToken'),
      bindingDigest: any(named: 'bindingDigest'),
      claim: any(named: 'claim'),
    ),
  ).thenAnswer((invocation) async {
    final claim = invocation.namedArguments[#claim] as ForegroundTransportClaim;
    currentLease = currentLease!.copyWith(foregroundActivityClaims: {claim});
    return currentLease;
  });
  when(
    () => leases.endForegroundActivityForOwner(
      runToken: any(named: 'runToken'),
      bindingDigest: any(named: 'bindingDigest'),
      claim: any(named: 'claim'),
    ),
  ).thenAnswer((_) async {
    currentLease = currentLease!.copyWith(foregroundActivityClaims: const {});
    return currentLease;
  });
  when(() => leases.releaseExact(any())).thenAnswer((_) async {
    currentLease = null;
    return true;
  });
  return (
    arbiter: BackupExecutionArbiter(
      leases: leases,
      tasks: tasks,
      foregroundFence: foregroundFence,
      tokenFactory: () => 'run-token',
    ),
    leases: leases,
  );
}

BackupRunBinding _binding() => BackupRunBinding(
  userId: 'user-a',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: 3,
  apiEndpoint: Uri.parse('https://photos.example/api'),
  canonicalOrigin: Uri.parse('https://photos.example'),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportEpoch: 1,
  transportRevision: 4,
  localLeaseRevision: 5,
);

BackupExecutionLease _lease(String digest) => BackupExecutionLease(
  mode: BackupExecutionMode.foreground,
  runToken: 'run-token',
  bindingDigest: digest,
  expiresAt: DateTime.utc(2026, 8, 12, 12),
  activityRevision: 0,
  callbacksInFlight: 0,
);
