import 'dart:async';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());
    registerFallbackValue(
      EagerBackgroundUploadOwner(runToken: 'fallback-run', bindingDigest: 'fallback-binding', claims: const {}),
    );
  });

  test('eager foreground and background events project into the existing Drift presenter', () async {
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      _MockBackgroundUploadService(),
      UploadSpeedManager(),
      _MockBackgroundBackupAdmissionPort(),
      _CurrentBindingSource(_binding()),
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);

    const waitingSnapshot = EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 1, pausedCount: 0);
    notifier.presentBackgroundSnapshot(waitingSnapshot);
    notifier.presentActivity(
      const BackupUploadActivity(
        kind: BackupUploadActivityKind.progress,
        localAssetId: 'asset-a',
        filename: 'video.mov',
        progress: 0.5,
        totalBytes: 100,
      ),
    );
    notifier.presentActivity(
      const BackupUploadActivity(
        kind: BackupUploadActivityKind.iCloudProgress,
        localAssetId: 'asset-a',
        progress: 0.25,
      ),
    );

    expect(notifier.state.isSyncing, isTrue);
    expect(notifier.state.backgroundUploadSnapshot, waitingSnapshot);
    expect(notifier.state.uploadItems['asset-a']?.progress, 0.5);
    expect(notifier.state.iCloudDownloadProgress['asset-a'], 0.25);

    notifier.presentActivity(
      const BackupUploadActivity(kind: BackupUploadActivityKind.error, localAssetId: 'asset-a', error: 'upload failed'),
    );
    expect(notifier.state.uploadItems['asset-a']?.isFailed, isTrue);

    notifier.presentBackgroundSnapshot(
      const EagerBackgroundUploadSnapshot(activeCount: 0, waitingToRetryCount: 0, pausedCount: 0),
    );
    expect(notifier.state.isSyncing, isFalse);
  });

  test('late callback from a completed direct foreground run stays fenced out', () async {
    final foregroundUploads = _MockForegroundUploadService();
    late UploadCallbacks callbacks;
    when(() => foregroundUploads.uploadCandidates(any(), any(), callbacks: any(named: 'callbacks'))).thenAnswer((
      invocation,
    ) async {
      callbacks = invocation.namedArguments[#callbacks] as UploadCallbacks;
      return const ForegroundUploadResult.completed();
    });
    final notifier = DriftBackupNotifier(
      foregroundUploads,
      _MockBackgroundUploadService(),
      UploadSpeedManager(),
      _MockBackgroundBackupAdmissionPort(),
      _CurrentBindingSource(_binding()),
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);

    await notifier.startForegroundBackup('user-a');
    callbacks.onProgress?.call('late-asset', 'late.mov', 50, 100);

    expect(notifier.state.uploadItems, isEmpty);
  });

  test('starting foreground work clears a stale background owner snapshot', () async {
    final foregroundUploads = _MockForegroundUploadService();
    when(
      () => foregroundUploads.uploadCandidates(any(), any(), callbacks: any(named: 'callbacks')),
    ).thenAnswer((_) async => const ForegroundUploadResult.completed());
    final notifier = DriftBackupNotifier(
      foregroundUploads,
      _MockBackgroundUploadService(),
      UploadSpeedManager(),
      _MockBackgroundBackupAdmissionPort(),
      _CurrentBindingSource(_binding()),
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);
    notifier.presentBackgroundSnapshot(
      const EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 0, pausedCount: 1),
    );

    await notifier.startForegroundBackup('user-a');

    expect(notifier.state.backgroundUploadSnapshot, isNull);
  });

  test('stale binding immediately after background acquire releases the durable lease', () async {
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    addTearDown(db.close);
    final leases = DriftBackupExecutionLeaseRepository(db);
    final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
    final backgroundUploads = _MockBackgroundUploadService();
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      backgroundUploads,
      UploadSpeedManager(),
      arbiter,
      _StaleBindingSource(_binding()),
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);

    await notifier.startBackupWithURLSession('user-a');

    expect(await leases.read(), isNull);
  });

  for (final phase in [DurableBackupEnablementPhase.disabling, DurableBackupEnablementPhase.drainFailed]) {
    final trigger = phase == DurableBackupEnablementPhase.disabling ? 'scheduled' : 'retry';
    test('$trigger adopted background never resumes while durable authority is ${phase.name}', () async {
      final backgroundUploads = _MockBackgroundUploadService();
      final admissions = _MockBackgroundBackupAdmissionPort();
      final binding = _binding();
      final lease = _lease(binding.digest);
      when(
        () => admissions.acquireBackground(bindingDigest: binding.digest),
      ).thenAnswer((_) async => BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: lease));
      final notifier = DriftBackupNotifier(
        _MockForegroundUploadService(),
        backgroundUploads,
        UploadSpeedManager(),
        admissions,
        _CurrentBindingSource(binding),
        _AuthoritySequence([DurableBackupEnablementPhase.enabled, phase]),
      );
      addTearDown(notifier.dispose);

      await notifier.startBackupWithURLSession('user-a');

      verifyNever(() => backgroundUploads.resumeOwned(any()));
      verify(() => admissions.acquireBackground(bindingDigest: binding.digest)).called(1);
    });
  }

  test('adopted background resumes exactly once with the admitted lease owner', () async {
    final backgroundUploads = _MockBackgroundUploadService();
    final admissions = _MockBackgroundBackupAdmissionPort();
    final binding = _binding();
    final lease = _lease(binding.digest);
    when(
      () => admissions.acquireBackground(bindingDigest: binding.digest),
    ).thenAnswer((_) async => BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: lease));
    when(() => backgroundUploads.readSnapshot(any())).thenAnswer(
      (_) async => const EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 0, pausedCount: 0),
    );
    when(
      () => backgroundUploads.resumeOwned(any()),
    ).thenAnswer((_) async => EagerBackgroundResumeDisposition.observing);
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      backgroundUploads,
      UploadSpeedManager(),
      admissions,
      _CurrentBindingSource(binding),
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);

    await notifier.startBackupWithURLSession('user-a');

    final owner =
        verify(() => backgroundUploads.resumeOwned(captureAny())).captured.single as EagerBackgroundUploadOwner;
    expect(owner.runToken, lease.runToken);
    expect(owner.bindingDigest, lease.bindingDigest);
    verify(() => backgroundUploads.readSnapshot(any())).called(1);
  });

  test('session change after admission prevents snapshot and unsafe resume', () async {
    final backgroundUploads = _MockBackgroundUploadService();
    final admissions = _MockBackgroundBackupAdmissionPort();
    final binding = _binding();
    final lease = _lease(binding.digest);
    final admission = Completer<BackupAdmission>();
    final bindings = _MutableBindingSource(binding);
    when(() => admissions.acquireBackground(bindingDigest: binding.digest)).thenAnswer((_) => admission.future);
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      backgroundUploads,
      UploadSpeedManager(),
      admissions,
      bindings,
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);

    final operation = notifier.startBackupWithURLSession('user-a');
    await pumpEventQueue();
    bindings.current = false;
    admission.complete(BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: lease));
    await operation;

    verifyNever(() => backgroundUploads.readSnapshot(any()));
    verifyNever(() => backgroundUploads.resumeOwned(any()));
  });

  test('session change during owner snapshot prevents unsafe resume', () async {
    final backgroundUploads = _MockBackgroundUploadService();
    final admissions = _MockBackgroundBackupAdmissionPort();
    final binding = _binding();
    final lease = _lease(binding.digest);
    final snapshot = Completer<EagerBackgroundUploadSnapshot>();
    final bindings = _MutableBindingSource(binding);
    when(
      () => admissions.acquireBackground(bindingDigest: binding.digest),
    ).thenAnswer((_) async => BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: lease));
    when(() => backgroundUploads.readSnapshot(any())).thenAnswer((_) => snapshot.future);
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      backgroundUploads,
      UploadSpeedManager(),
      admissions,
      bindings,
      const _Authority(DurableBackupEnablementPhase.enabled),
    );
    addTearDown(notifier.dispose);

    final operation = notifier.startBackupWithURLSession('user-a');
    await pumpEventQueue();
    bindings.current = false;
    snapshot.complete(const EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 0, pausedCount: 0));
    await operation;

    verify(() => backgroundUploads.readSnapshot(any())).called(1);
    verifyNever(() => backgroundUploads.resumeOwned(any()));
  });

  test('adopted owner snapshot timeout fails closed without resume', () async {
    final backgroundUploads = _MockBackgroundUploadService();
    final admissions = _MockBackgroundBackupAdmissionPort();
    final binding = _binding();
    final lease = _lease(binding.digest);
    final snapshot = Completer<EagerBackgroundUploadSnapshot>();
    when(
      () => admissions.acquireBackground(bindingDigest: binding.digest),
    ).thenAnswer((_) async => BackupAdmission(BackupAdmissionDisposition.adoptedBackground, lease: lease));
    when(() => backgroundUploads.readSnapshot(any())).thenAnswer((_) => snapshot.future);
    when(
      () => backgroundUploads.resumeOwned(any()),
    ).thenAnswer((_) async => EagerBackgroundResumeDisposition.observing);
    final notifier = DriftBackupNotifier(
      _MockForegroundUploadService(),
      backgroundUploads,
      UploadSpeedManager(),
      admissions,
      _CurrentBindingSource(binding),
      const _Authority(DurableBackupEnablementPhase.enabled),
      backgroundOwnerTimeout: const Duration(milliseconds: 5),
    );
    addTearDown(notifier.dispose);

    var completed = false;
    final operation = notifier.startBackupWithURLSession('user-a').whenComplete(() => completed = true);
    await Future<void>.delayed(const Duration(milliseconds: 20));
    snapshot.complete(const EagerBackgroundUploadSnapshot(activeCount: 1, waitingToRetryCount: 0, pausedCount: 0));
    await operation;

    expect(completed, isTrue);
    verify(() => backgroundUploads.readSnapshot(any())).called(1);
    verifyNever(() => backgroundUploads.resumeOwned(any()));
  });
}

BackupExecutionLease _lease(String bindingDigest) => BackupExecutionLease(
  mode: BackupExecutionMode.background,
  runToken: 'owned-run',
  bindingDigest: bindingDigest,
  expiresAt: DateTime.utc(2026, 8, 12, 12).add(const Duration(minutes: 2)),
  activityRevision: 1,
  callbacksInFlight: 0,
);

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

final class _StaleBindingSource implements BackupRunBindingSourcePort {
  const _StaleBindingSource(this.binding);

  final BackupRunBinding binding;

  @override
  BackupRunBinding? capture() => binding;

  @override
  bool isCurrent(BackupRunBinding binding) => false;
}

final class _CurrentBindingSource implements BackupRunBindingSourcePort {
  const _CurrentBindingSource(this.binding);

  final BackupRunBinding binding;

  @override
  BackupRunBinding? capture() => binding;

  @override
  bool isCurrent(BackupRunBinding binding) => binding == this.binding;
}

final class _MutableBindingSource implements BackupRunBindingSourcePort {
  _MutableBindingSource(this.binding);

  final BackupRunBinding binding;
  bool current = true;

  @override
  BackupRunBinding? capture() => binding;

  @override
  bool isCurrent(BackupRunBinding binding) => current && binding == this.binding;
}

final class _Authority implements BackupEnablementAuthorityPort {
  const _Authority(this.phase);

  final DurableBackupEnablementPhase phase;

  @override
  Future<DurableBackupEnablementState?> readAuthority() async =>
      DurableBackupEnablementState(phase: phase, generation: 4);
}

final class _AuthoritySequence implements BackupEnablementAuthorityPort {
  _AuthoritySequence(List<DurableBackupEnablementPhase> phases) : _phases = List.of(phases);

  final List<DurableBackupEnablementPhase> _phases;
  int _generation = 3;

  @override
  Future<DurableBackupEnablementState?> readAuthority() async =>
      DurableBackupEnablementState(phase: _phases.removeAt(0), generation: ++_generation);
}

final class _EmptyRegistry implements BackupTaskRegistryPort {
  const _EmptyRegistry();

  @override
  Future<void> get ready async {}

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async => const [];

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) async => true;
}

class _MockForegroundUploadService extends Mock implements ForegroundUploadService {}

class _MockBackgroundUploadService extends Mock implements BackgroundUploadService {}

class _MockBackgroundBackupAdmissionPort extends Mock implements BackgroundBackupAdmissionPort {}
