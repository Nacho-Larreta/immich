import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/providers/backup/eager_backup.provider.dart';
import 'package:immich_mobile/domain/services/backup_enablement_controller.dart';
import 'package:immich_mobile/providers/backup/backup_enablement.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';

void main() {
  test('cold start wires workload and connectivity before current proof starts exactly one upload', () async {
    final harness = _Harness(userId: 'user-a');
    addTearDown(harness.dispose);

    harness.start();
    await pumpEventQueue();
    harness.workloads.emit(const BackupWorkload(total: 2, remainder: 2, processing: 0));
    await pumpEventQueue();

    expect(harness.operations.uploadCount, 0);
    expect(harness.diagnostics.codes, contains(EagerBackupDiagnosticCode.workloadFirstEmission));
    expect(harness.diagnostics.codes, contains(EagerBackupDiagnosticCode.connectivitySnapshot));

    harness.publishCurrentProof();
    await pumpEventQueue();
    await harness.operations.uploaded.future.timeout(const Duration(seconds: 2));

    expect(harness.operations.uploadCount, 1);
  });

  test('cold start without a user subscribes when the user later becomes available', () async {
    final harness = _Harness(userId: null);
    addTearDown(harness.dispose);

    harness.start();
    harness.publishCurrentProof();
    await pumpEventQueue();

    expect(harness.workloads.listenCount, 0);
    expect(harness.operations.uploadCount, 0);

    harness.setUser('user-a');
    await pumpEventQueue();
    harness.workloads.emit(const BackupWorkload(total: 2, remainder: 2, processing: 0));
    await pumpEventQueue();
    await harness.operations.uploaded.future.timeout(const Duration(seconds: 2));

    expect(harness.workloads.listenCount, 1);
    expect(harness.operations.uploadCount, 1);
  });
}

final class _Harness {
  _Harness({required String? userId})
    : connectivity = _Connectivity(),
      workloads = _Workloads(),
      operations = _Operations(userPresent: userId != null),
      diagnostics = _Diagnostics(),
      photoObserver = _PhotoObserver(),
      enablement = BackupEnablementController(_EnablementPort(), initiallyEnabled: true) {
    container = ProviderContainer(
      overrides: [
        eagerBackupUserIdProvider.overrideWithValue(userId),
        eagerBackupEnabledProvider.overrideWithValue(true),
        eagerBackupEnabledChangesProvider.overrideWithValue(const Stream.empty()),
        eagerBackupOperationsProvider.overrideWithValue(operations),
        eagerBackupWorkloadMonitorProvider.overrideWithValue(workloads),
        eagerBackupDiagnosticsProvider.overrideWithValue(diagnostics),
        eagerBackupPhotoObserverFactoryProvider.overrideWithValue((_) => photoObserver),
        eagerBackupResumeReconciliationsProvider.overrideWithValue(() async {}),
        nativeConnectivityMonitorProvider.overrideWithValue(connectivity),
        backupEnablementControllerProvider.overrideWithValue(enablement),
      ],
    );
  }

  final _Connectivity connectivity;
  final _Workloads workloads;
  final _Operations operations;
  final _Diagnostics diagnostics;
  final _PhotoObserver photoObserver;
  final BackupEnablementController enablement;
  late final ProviderContainer container;

  void start() => container.read(eagerBackupStartupProvider);

  void setUser(String userId) {
    operations.userPresent = true;
    container.updateOverrides([
      eagerBackupUserIdProvider.overrideWithValue(userId),
      eagerBackupEnabledProvider.overrideWithValue(true),
      eagerBackupEnabledChangesProvider.overrideWithValue(const Stream.empty()),
      eagerBackupOperationsProvider.overrideWithValue(operations),
      eagerBackupWorkloadMonitorProvider.overrideWithValue(workloads),
      eagerBackupDiagnosticsProvider.overrideWithValue(diagnostics),
      eagerBackupPhotoObserverFactoryProvider.overrideWithValue((_) => photoObserver),
      eagerBackupResumeReconciliationsProvider.overrideWithValue(() async {}),
      nativeConnectivityMonitorProvider.overrideWithValue(connectivity),
      backupEnablementControllerProvider.overrideWithValue(enablement),
    ]);
  }

  void publishCurrentProof() {
    final endpoint = Uri.parse('https://photos.example/api');
    container.read(serverReachabilityStateProvider.notifier).state = ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 1,
      probeGeneration: 1,
      confirmedEndpoint: endpoint,
      serverAccess: ConfirmedServerAccess(
        apiEndpoint: endpoint,
        canonicalOrigin: Uri.parse('https://photos.example'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: 1,
        confirmed: true,
        fenced: false,
      ),
    );
  }

  Future<void> dispose() async {
    container.dispose();
    await enablement.dispose();
    await pumpEventQueue();
    await workloads.dispose();
  }
}

final class _EnablementPort implements BackupEnablementPort {
  @override
  Future<bool> admitsBackupWork() async => true;

  @override
  Future<DurableBackupEnablementState> beginDisable() async =>
      const DurableBackupEnablementState(phase: DurableBackupEnablementPhase.disabling, generation: 1);

  @override
  Future<bool> completeDrain(DurableBackupEnablementState disabling) async => true;

  @override
  Future<bool> drain() async => true;

  @override
  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained) async => true;

  @override
  Future<bool> failDrain(DurableBackupEnablementState disabling) async => true;

  @override
  Future<DurableBackupEnablementState> initialize(bool legacyEnabled) async =>
      const DurableBackupEnablementState(phase: DurableBackupEnablementPhase.enabled, generation: 0);

  @override
  void reportDrainFailed() {}

  @override
  void signalSettingChanged() {}

  @override
  void stopEager() {}
}

final class _Connectivity implements ConnectivityMonitorPort, ConnectivitySnapshotMonitorPort {
  final StreamController<BackupTransportSnapshot> _snapshots = StreamController.broadcast(sync: true);
  final StreamController<TransportAvailability> _availability = StreamController.broadcast(sync: true);

  final BackupTransportSnapshot snapshot = const BackupTransportSnapshot(
    available: true,
    capabilities: {BackupNetworkCapability.wifi},
    monitorEpoch: 1,
    revision: 1,
  );

  @override
  Future<BackupTransportSnapshot> get initialSnapshot async {
    scheduleMicrotask(() => _snapshots.add(snapshot));
    return snapshot;
  }

  @override
  Stream<BackupTransportSnapshot> get snapshotEvents => _snapshots.stream;

  @override
  Future<BackupTransportSnapshot> readCurrentSnapshot() async => snapshot;

  @override
  Future<TransportAvailability> get initialAvailability async => TransportAvailability.available;

  @override
  Stream<TransportAvailability> get events => _availability.stream;

  @override
  Future<void> dispose() async {}
}

final class _Workloads implements EagerBackupWorkloadMonitorPort {
  _Workloads() {
    _controller = StreamController.broadcast(sync: true, onListen: () => listenCount++);
  }

  late final StreamController<BackupWorkload> _controller;
  int listenCount = 0;

  void emit(BackupWorkload workload) => _controller.add(workload);

  @override
  Stream<BackupWorkload> watch(String userId) => _controller.stream;

  Future<void> dispose() => _controller.close();
}

final class _Operations implements EagerBackupOperationsPort {
  _Operations({required this.userPresent});

  final Completer<void> uploaded = Completer<void>();
  bool userPresent;
  int uploadCount = 0;
  bool _uploadCompleted = false;

  @override
  Future<bool> hasReconciliationQuarantine() async => false;

  @override
  Future<BackupRunBinding?> captureBinding() async => BackupRunBinding(
    userId: 'user-a',
    sessionEpoch: 1,
    probeGeneration: 1,
    nativeGeneration: 1,
    apiEndpoint: Uri.parse('https://photos.example/api'),
    canonicalOrigin: Uri.parse('https://photos.example'),
    schemePolicy: EndpointSchemePolicy.httpsOnly,
    transportEpoch: 1,
    transportRevision: 1,
    localLeaseRevision: 1,
  );

  @override
  Future<void> hashAssets(EagerBackupCancellation cancellation) async {}

  @override
  Future<BackupWorkload> readWorkload() async => userPresent && !_uploadCompleted
      ? const BackupWorkload(total: 2, remainder: 2, processing: 0)
      : const BackupWorkload(total: 0, remainder: 0, processing: 0);

  @override
  Future<void> synchronizeLocal(EagerBackupCancellation cancellation) async {}

  @override
  Future<EagerBackupUploadOutcome> upload(BackupRunBinding binding, EagerBackupCancellation cancellation) async {
    uploadCount++;
    _uploadCompleted = true;
    if (!uploaded.isCompleted) uploaded.complete();
    return EagerBackupUploadOutcome.completed;
  }
}

final class _Diagnostics implements EagerBackupDiagnosticsPort {
  final List<EagerBackupDiagnosticEvent> events = [];

  List<EagerBackupDiagnosticCode> get codes => events.map((event) => event.code).toList();

  @override
  void report(EagerBackupDiagnosticEvent event) => events.add(event);
}

final class _PhotoObserver implements EagerBackupPhotoObserverPort {
  @override
  Future<void> dispose() async {}

  @override
  Future<void> start() async {}
}
