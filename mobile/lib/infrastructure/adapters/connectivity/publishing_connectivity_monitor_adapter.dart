import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

final class PublishingConnectivityMonitorAdapter implements ConnectivityMonitorPort {
  PublishingConnectivityMonitorAdapter({
    required ConnectivityMonitorPort delegate,
    required void Function(TransportAvailability availability) publish,
  }) : _delegate = delegate,
       _publish = publish;

  final ConnectivityMonitorPort _delegate;
  final void Function(TransportAvailability availability) _publish;
  int _eventRevision = 0;

  @override
  Future<TransportAvailability> get initialAvailability async {
    final revisionBeforeLoad = _eventRevision;
    final availability = await _delegate.initialAvailability;
    if (revisionBeforeLoad == _eventRevision) {
      _publish(availability);
    }
    return availability;
  }

  @override
  Stream<TransportAvailability> get events {
    return _delegate.events.map((availability) {
      _eventRevision++;
      _publish(availability);
      return availability;
    });
  }

  @override
  Future<void> dispose() => _delegate.dispose();
}
