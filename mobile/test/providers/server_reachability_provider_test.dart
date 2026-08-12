import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_activation.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe_cycle.interface.dart';
import 'package:immich_mobile/domain/interfaces/reconciliation.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup.provider.dart';

void main() {
  test('owns one eager-started coordinator instance per container and disposes it once', () async {
    final firstConnectivity = _FakeConnectivityMonitor();
    final secondConnectivity = _FakeConnectivityMonitor();
    final firstContainer = _container(firstConnectivity);
    final secondContainer = _container(secondConnectivity);

    expect(firstContainer.read(transportAvailabilityProvider), TransportAvailability.unknown);

    final firstRead = firstContainer.read(serverReachabilityCoordinatorProvider);
    final repeatedRead = firstContainer.read(serverReachabilityCoordinatorProvider);
    final secondRead = secondContainer.read(serverReachabilityCoordinatorProvider);
    await pumpEventQueue();

    expect(identical(firstRead, repeatedRead), isTrue);
    expect(identical(firstRead, secondRead), isFalse);
    expect(firstConnectivity.listenCount, 1);
    expect(secondConnectivity.listenCount, 1);

    firstConnectivity.emit(TransportAvailability.available);
    await pumpEventQueue();
    expect(firstContainer.read(transportAvailabilityProvider), TransportAvailability.available);

    firstContainer.dispose();
    secondContainer.dispose();
    await Future.wait([firstConnectivity.disposed.future, secondConnectivity.disposed.future]);

    expect(firstConnectivity.disposeCount, 1);
    expect(secondConnectivity.disposeCount, 1);
  });
}

ProviderContainer _container(_FakeConnectivityMonitor connectivity) {
  return ProviderContainer(
    overrides: [
      nativeConnectivityMonitorProvider.overrideWithValue(connectivity),
      endpointProbeCycleProvider.overrideWithValue(const _UnusedProbeCycles()),
      endpointActivationProvider.overrideWithValue(const _UnusedActivations()),
      reconciliationProvider.overrideWithValue(const _UnusedReconciliations()),
      eagerBackupStartupProvider.overrideWith((_) {}),
    ],
  );
}

final class _FakeConnectivityMonitor implements ConnectivityMonitorPort {
  late final StreamController<TransportAvailability> _events = StreamController.broadcast(
    onListen: () => listenCount++,
  );
  final disposed = Completer<void>();
  int listenCount = 0;
  int disposeCount = 0;

  void emit(TransportAvailability availability) => _events.add(availability);

  @override
  Stream<TransportAvailability> get events => _events.stream;

  @override
  Future<TransportAvailability> get initialAvailability async => TransportAvailability.unknown;

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _events.close();
    if (!disposed.isCompleted) {
      disposed.complete();
    }
  }
}

final class _UnusedProbeCycles implements EndpointProbeCyclePort {
  const _UnusedProbeCycles();

  @override
  CancellableRequest<EndpointProbeResult> begin(ReachabilityIdentity identity) {
    throw StateError('No probe expected');
  }
}

final class _UnusedActivations implements EndpointActivationPort {
  const _UnusedActivations();

  @override
  CancellableRequest<OfflineResult<EndpointActivationReceipt>> activate(EndpointActivationRequest request) {
    throw StateError('No activation expected');
  }
}

final class _UnusedReconciliations implements ReconciliationPort {
  const _UnusedReconciliations();

  @override
  CancellableRequest<OfflineResult<OperationCompletion>> reconcile(ReconciliationRequest request) {
    throw StateError('No reconciliation expected');
  }
}
