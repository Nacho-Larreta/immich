import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/connectivity/publishing_connectivity_monitor_adapter.dart';

void main() {
  test('publishes initial and event availability through the coordinator subscription', () async {
    final delegate = _ConnectivityMonitor();
    final published = <TransportAvailability>[];
    final adapter = PublishingConnectivityMonitorAdapter(delegate: delegate, publish: published.add);

    expect(await adapter.initialAvailability, TransportAvailability.available);
    final received = <TransportAvailability>[];
    final subscription = adapter.events.listen(received.add);
    delegate.eventsController.add(TransportAvailability.unavailable);
    await pumpEventQueue();

    expect(published, [TransportAvailability.available, TransportAvailability.unavailable]);
    expect(received, [TransportAvailability.unavailable]);
    expect(delegate.listenCount, 1);

    await subscription.cancel();
    await adapter.dispose();
    expect(delegate.disposeCount, 1);
  });

  test('does not let a late initial snapshot overwrite a newer transport event', () async {
    final initial = Completer<TransportAvailability>();
    final delegate = _ConnectivityMonitor(initialAvailability: initial.future);
    final published = <TransportAvailability>[];
    final adapter = PublishingConnectivityMonitorAdapter(delegate: delegate, publish: published.add);
    final initialLoad = adapter.initialAvailability;
    final subscription = adapter.events.listen((_) {});

    delegate.eventsController.add(TransportAvailability.available);
    await pumpEventQueue();
    initial.complete(TransportAvailability.unavailable);

    expect(await initialLoad, TransportAvailability.unavailable);
    expect(published, [TransportAvailability.available]);
    await subscription.cancel();
    await adapter.dispose();
  });
}

final class _ConnectivityMonitor implements ConnectivityMonitorPort {
  _ConnectivityMonitor({Future<TransportAvailability>? initialAvailability})
    : _initialAvailability = initialAvailability ?? Future.value(TransportAvailability.available);

  final Future<TransportAvailability> _initialAvailability;
  late final StreamController<TransportAvailability> eventsController = StreamController.broadcast(
    onListen: () => listenCount++,
  );
  int listenCount = 0;
  int disposeCount = 0;

  @override
  Stream<TransportAvailability> get events => eventsController.stream;

  @override
  Future<TransportAvailability> get initialAvailability => _initialAvailability;

  @override
  Future<void> dispose() async {
    disposeCount++;
    await eventsController.close();
  }
}
