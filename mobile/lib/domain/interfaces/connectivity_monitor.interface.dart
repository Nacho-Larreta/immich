import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';

abstract interface class ConnectivityMonitorPort {
  Future<TransportAvailability> get initialAvailability;

  Stream<TransportAvailability> get events;

  Future<void> dispose();
}

abstract interface class ConnectivitySnapshotMonitorPort {
  Future<BackupTransportSnapshot> get initialSnapshot;

  Stream<BackupTransportSnapshot> get snapshotEvents;

  Future<BackupTransportSnapshot> readCurrentSnapshot();
}
