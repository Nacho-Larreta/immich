import 'package:immich_mobile/domain/models/server_reachability.model.dart';

abstract interface class ConnectivityMonitorPort {
  Future<TransportAvailability> get initialAvailability;

  Stream<TransportAvailability> get events;

  Future<void> dispose();
}
