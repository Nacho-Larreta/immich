import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/services/eager_backup_coordinator.dart';
import 'package:immich_mobile/providers/backup/eager_backup.provider.dart';

void main() {
  test('throwing diagnostics cannot alter upload phases or disposal', () async {
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 0, remainder: 0, processing: 0),
    ]);
    final coordinator = EagerBackupCoordinator(operations: operations, diagnostics: const _ThrowingDiagnostics())
      ..setEnabled(true)
      ..setForeground(true)
      ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.wifi}))
      ..setServerProofAvailable(true)
      ..signal(EagerBackupTrigger.startup);

    await operations.done.future;
    await pumpEventQueue();

    expect(operations.calls, contains('upload'));
    expect(coordinator.state.phase, EagerBackupPhase.idle);
    await expectLater(coordinator.dispose(), completes);
    expect(coordinator.state.phase, EagerBackupPhase.disposed);
  });

  test('throwing diagnostics cannot prevent retry scheduling', () async {
    final retry = _ManualRetryScheduler();
    final operations = _Operations(
      [
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
      ],
      uploadFailures: [const EagerBackupFailure.transient()],
    );
    final coordinator =
        EagerBackupCoordinator(operations: operations, retryScheduler: retry, diagnostics: const _ThrowingDiagnostics())
          ..setEnabled(true)
          ..setForeground(true)
          ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.wifi}))
          ..setServerProofAvailable(true)
          ..signal(EagerBackupTrigger.startup);

    await operations.uploadStarted.future;
    await pumpEventQueue();

    expect(coordinator.state.phase, EagerBackupPhase.backingOff);
    expect(retry.delays, hasLength(1));
    await coordinator.dispose();
  });

  test('reports triggers and state transitions with allowlisted workload counts', () async {
    final operations = _Operations([
      const BackupWorkload(total: 2, remainder: 2, processing: 0),
      const BackupWorkload(total: 2, remainder: 2, processing: 0),
    ]);
    final diagnostics = _Diagnostics();
    final coordinator = EagerBackupCoordinator(operations: operations, diagnostics: diagnostics)
      ..setEnabled(true)
      ..setForeground(true)
      ..signal(EagerBackupTrigger.startup);

    await pumpEventQueue();

    expect(
      diagnostics.events
          .where((event) => event.code == EagerBackupDiagnosticCode.triggerReceived)
          .map((event) => event.trigger),
      contains(EagerBackupTrigger.startup),
    );
    expect(
      diagnostics.events.where((event) => event.code == EagerBackupDiagnosticCode.phaseChanged).last,
      isA<EagerBackupDiagnosticEvent>()
          .having((event) => event.phase, 'phase', EagerBackupPhase.blocked)
          .having((event) => event.blocker, 'blocker', EagerBackupBlocker.noWifi)
          .having((event) => event.ready, 'ready', 2)
          .having((event) => event.processing, 'processing', 0),
    );

    await coordinator.dispose();
  });

  test('state provider publishes typed noWifi, leaseOwned, and drainFailed blockers', () async {
    final operations = _Operations(const []);
    final coordinator = EagerBackupCoordinator(operations: operations);
    final container = ProviderContainer(overrides: [eagerBackupCoordinatorProvider.overrideWithValue(coordinator)]);
    final blockers = <EagerBackupBlocker>[];
    final subscription = container.listen<AsyncValue<EagerBackupState>>(
      eagerBackupStateProvider,
      (_, next) => next.whenData((state) {
        if (state.blocker case final blocker?) blockers.add(blocker);
      }),
      fireImmediately: true,
    );

    await pumpEventQueue();
    coordinator
      ..reportLeaseOwned()
      ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.wifi}))
      ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.cellular}))
      ..reportDrainFailed();
    await pumpEventQueue();

    expect(
      blockers,
      containsAll([EagerBackupBlocker.leaseOwned, EagerBackupBlocker.noWifi, EagerBackupBlocker.drainFailed]),
    );
    subscription.close();
    await coordinator.dispose().timeout(const Duration(seconds: 2));
    container.dispose();
  });

  test('processing workload is synchronized, hashed, then uploaded immediately', () async {
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 1),
      const BackupWorkload(total: 1, remainder: 1, processing: 1),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 0, processing: 0),
    ]);
    final coordinator = _readyCoordinator(operations);

    coordinator.signal(EagerBackupTrigger.startup);
    await operations.done.future;
    await pumpEventQueue();
    await pumpEventQueue();

    expect(operations.calls, ['read', 'syncLocal', 'read', 'hash', 'read', 'binding', 'upload', 'read']);
    expect(coordinator.state.phase, EagerBackupPhase.idle);
    await coordinator.dispose();
  });

  test('signals arriving during a run coalesce into exactly one rerun', () async {
    final upload = Completer<void>();
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 0, processing: 0),
    ], pendingUpload: upload);
    final coordinator = _readyCoordinator(operations);

    coordinator.signal(EagerBackupTrigger.startup);
    await operations.uploadStarted.future;
    coordinator
      ..signal(EagerBackupTrigger.photoLibraryChanged)
      ..signal(EagerBackupTrigger.workloadChanged)
      ..signal(EagerBackupTrigger.connectivityChanged);
    upload.complete();
    await operations.done.future;

    expect(operations.calls.where((call) => call == 'upload'), hasLength(1));
    expect(operations.calls.where((call) => call == 'read'), hasLength(3));
    await coordinator.dispose();
  });

  test('transport cursor change immediately re-evaluates with the next binding', () async {
    final operations = _Operations(
      [
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 0, processing: 0),
      ],
      uploadOutcomes: [EagerBackupUploadOutcome.transportCursorChanged, EagerBackupUploadOutcome.completed],
    );
    final coordinator = _readyCoordinator(operations);

    coordinator.signal(EagerBackupTrigger.startup);
    await operations.done.future;
    await pumpEventQueue();

    expect(operations.calls.where((call) => call == 'binding'), hasLength(2));
    expect(operations.calls.where((call) => call == 'upload'), hasLength(2));
    expect(coordinator.state.phase, EagerBackupPhase.idle);
    await coordinator.dispose();
  });

  test('wifi and proof arrival unblock retained demand without a new workload edge', () async {
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 0, processing: 0),
    ]);
    final coordinator = EagerBackupCoordinator(operations: operations)
      ..setEnabled(true)
      ..setForeground(true)
      ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.cellular}));

    coordinator.signal(EagerBackupTrigger.startup);
    await pumpEventQueue();
    expect(coordinator.state.phase, EagerBackupPhase.blocked);
    expect(operations.calls, ['read', 'syncLocal', 'read']);

    coordinator
      ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.wifi}))
      ..setServerProofAvailable(true);
    await operations.done.future;

    expect(operations.calls.where((call) => call == 'upload'), hasLength(1));
    await coordinator.dispose();
  });

  test('transient failure retries from retained demand with bounded injected backoff', () async {
    final retry = _ManualRetryScheduler();
    final operations = _Operations(
      [
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 0, processing: 0),
      ],
      uploadFailures: [const EagerBackupFailure.transient()],
    );
    final coordinator = _readyCoordinator(operations, retryScheduler: retry);

    coordinator.signal(EagerBackupTrigger.startup);
    await pumpEventQueue();

    expect(coordinator.state.phase, EagerBackupPhase.backingOff);
    expect(retry.delays, [const Duration(seconds: 1)]);
    retry.fire();
    await operations.done.future;
    expect(operations.calls.where((call) => call == 'upload'), hasLength(2));
    await coordinator.dispose();
  });

  test('unexpected upload failure is converted to bounded retry without losing demand', () async {
    final retry = _ManualRetryScheduler();
    final operations = _Operations(
      [
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 1, processing: 0),
        const BackupWorkload(total: 1, remainder: 0, processing: 0),
      ],
      uploadFailures: [StateError('unexpected')],
    );
    final coordinator = _readyCoordinator(operations, retryScheduler: retry);

    coordinator.signal(EagerBackupTrigger.startup);
    await pumpEventQueue();

    expect(coordinator.state.phase, EagerBackupPhase.backingOff);
    expect(retry.delays, [const Duration(seconds: 1)]);
    retry.fire();
    await operations.done.future;
    expect(operations.calls.where((call) => call == 'upload'), hasLength(2));
    await coordinator.dispose();
  });

  test('URLSession failure terminal enters typed backoff instead of a tight rerun', () async {
    final retry = _ManualRetryScheduler();
    final operations = _Operations(const []);
    final coordinator = EagerBackupCoordinator(operations: operations, retryScheduler: retry)..setEnabled(true);

    coordinator.signal(EagerBackupTrigger.uploadFailed);
    await pumpEventQueue();

    expect(coordinator.state.phase, EagerBackupPhase.backingOff);
    expect(retry.delays, [const Duration(seconds: 1)]);
    expect(operations.calls, isEmpty);
    await coordinator.dispose();
  });

  test('pause and disable synchronously cancel and block admission', () async {
    final upload = Completer<void>();
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
    ], pendingUpload: upload);
    final coordinator = _readyCoordinator(operations);

    coordinator.signal(EagerBackupTrigger.startup);
    await operations.uploadStarted.future;
    coordinator.setForeground(false);

    expect(operations.cancellation?.isCancelled, isTrue);
    coordinator.setEnabled(false);
    upload.complete();
    await pumpEventQueue();
    expect(coordinator.state.phase, EagerBackupPhase.blocked);
    await coordinator.dispose();
  });

  test('charging and configured delay are not eager foreground gates', () async {
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 0, processing: 0),
    ]);
    final coordinator = _readyCoordinator(operations);

    coordinator.signal(EagerBackupTrigger.startup);
    await operations.done.future;

    expect(operations.calls, contains('upload'));
    await coordinator.dispose();
  });

  test('enabling after a disabled startup creates eager demand without another edge', () async {
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 0, processing: 0),
    ]);
    final coordinator = EagerBackupCoordinator(operations: operations);
    coordinator
      ..setForeground(true)
      ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.wifi}))
      ..setServerProofAvailable(true)
      ..signal(EagerBackupTrigger.startup);

    coordinator.setEnabled(true);
    await operations.done.future;

    expect(operations.calls.where((call) => call == 'upload'), hasLength(1));
    await coordinator.dispose();
  });

  test('wifi loss synchronously cancels an admitted foreground run', () async {
    final upload = Completer<void>();
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
    ], pendingUpload: upload);
    final coordinator = _readyCoordinator(operations);
    coordinator.signal(EagerBackupTrigger.startup);
    await operations.uploadStarted.future;

    coordinator.setTransport(
      const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.cellular}),
    );

    expect(operations.cancellation?.isCancelled, isTrue);
    upload.complete();
    await coordinator.dispose();
  });

  test('server proof loss synchronously cancels an admitted foreground run', () async {
    final upload = Completer<void>();
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
    ], pendingUpload: upload);
    final coordinator = _readyCoordinator(operations);
    coordinator.signal(EagerBackupTrigger.startup);
    await operations.uploadStarted.future;

    coordinator.setServerProofAvailable(false);

    expect(operations.cancellation?.isCancelled, isTrue);
    expect(coordinator.state.blocker, EagerBackupBlocker.noProof);
    upload.complete();
    await coordinator.dispose();
  });

  test('pause handoff times out without admitting a second owner', () async {
    final upload = Completer<void>();
    final operations = _Operations([
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
      const BackupWorkload(total: 1, remainder: 1, processing: 0),
    ], pendingUpload: upload);
    final coordinator = _readyCoordinator(operations);
    coordinator.signal(EagerBackupTrigger.startup);
    await operations.uploadStarted.future;

    expect(await coordinator.suspendForeground(timeout: const Duration(milliseconds: 5)), isFalse);
    expect(operations.calls.where((call) => call == 'upload'), hasLength(1));

    upload.complete();
    await coordinator.dispose();
  });
}

EagerBackupCoordinator _readyCoordinator(_Operations operations, {EagerBackupRetryScheduler? retryScheduler}) {
  return EagerBackupCoordinator(operations: operations, retryScheduler: retryScheduler)
    ..setEnabled(true)
    ..setForeground(true)
    ..setTransport(const BackupTransportSnapshot(available: true, capabilities: {BackupNetworkCapability.wifi}))
    ..setServerProofAvailable(true);
}

final class _Operations implements EagerBackupOperationsPort {
  _Operations(
    this.workloads, {
    this.pendingUpload,
    List<Object>? uploadFailures,
    List<EagerBackupUploadOutcome>? uploadOutcomes,
  }) : uploadFailures = List.of(uploadFailures ?? const []),
       uploadOutcomes = List.of(uploadOutcomes ?? const []);

  final List<BackupWorkload> workloads;
  final Completer<void>? pendingUpload;
  final List<Object> uploadFailures;
  final List<EagerBackupUploadOutcome> uploadOutcomes;
  final List<String> calls = [];
  final Completer<void> uploadStarted = Completer<void>();
  final Completer<void> done = Completer<void>();
  EagerBackupCancellation? cancellation;

  @override
  Future<BackupRunBinding?> captureBinding() async {
    calls.add('binding');
    return BackupRunBinding(
      userId: 'user',
      sessionEpoch: 1,
      probeGeneration: 2,
      nativeGeneration: 3,
      apiEndpoint: Uri.parse('https://photos.test/api'),
      canonicalOrigin: Uri.parse('https://photos.test'),
      schemePolicy: EndpointSchemePolicy.httpsOnly,
      transportEpoch: 1,
      transportRevision: 4,
      localLeaseRevision: 5,
    );
  }

  @override
  Future<void> hashAssets(EagerBackupCancellation cancellation) async {
    calls.add('hash');
  }

  @override
  Future<BackupWorkload> readWorkload() async {
    calls.add('read');
    final workload = workloads.removeAt(0);
    if (workloads.isEmpty && workload.remainder == 0 && !done.isCompleted) {
      done.complete();
    }
    return workload;
  }

  @override
  Future<void> synchronizeLocal(EagerBackupCancellation cancellation) async {
    calls.add('syncLocal');
  }

  @override
  Future<EagerBackupUploadOutcome> upload(BackupRunBinding binding, EagerBackupCancellation cancellation) async {
    calls.add('upload');
    this.cancellation = cancellation;
    if (!uploadStarted.isCompleted) uploadStarted.complete();
    if (uploadFailures.isNotEmpty) throw uploadFailures.removeAt(0);
    await pendingUpload?.future;
    return uploadOutcomes.isEmpty ? EagerBackupUploadOutcome.completed : uploadOutcomes.removeAt(0);
  }
}

final class _ManualRetryScheduler implements EagerBackupRetryScheduler {
  final List<Duration> delays = [];
  void Function()? _callback;

  @override
  EagerBackupScheduledRetry schedule(Duration delay, void Function() callback) {
    delays.add(delay);
    _callback = callback;
    return _RetryHandle(() => _callback = null);
  }

  void fire() {
    final callback = _callback;
    _callback = null;
    callback?.call();
  }
}

final class _RetryHandle implements EagerBackupScheduledRetry {
  _RetryHandle(this._onCancel);
  final void Function() _onCancel;

  @override
  void cancel() => _onCancel();
}

final class _Diagnostics implements EagerBackupDiagnosticsPort {
  final List<EagerBackupDiagnosticEvent> events = [];

  @override
  void report(EagerBackupDiagnosticEvent event) => events.add(event);
}

final class _ThrowingDiagnostics implements EagerBackupDiagnosticsPort {
  const _ThrowingDiagnostics();

  @override
  void report(EagerBackupDiagnosticEvent event) => throw StateError('diagnostics unavailable');
}
