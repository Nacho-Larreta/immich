import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/connectivity_api.g.dart',
    swiftOut: 'ios/Runner/Connectivity/Connectivity.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/connectivity/Connectivity.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.connectivity'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum ConnectivityTransportAvailability { unknown, unavailable, available }

enum ConnectivityNetworkCapability { cellular, wifi, vpn, unmetered }

class ConnectivityTransportSnapshot {
  ConnectivityTransportSnapshot({
    required this.availability,
    required this.capabilities,
    required this.monitorEpoch,
    required this.revision,
  });

  ConnectivityTransportAvailability availability;
  List<ConnectivityNetworkCapability> capabilities;
  int monitorEpoch;
  int revision;
}

@HostApi()
abstract class ConnectivityApi {
  @TaskQueue(type: TaskQueueType.serialBackgroundThread)
  ConnectivityTransportSnapshot readCurrentSnapshot();

  void start();

  void stop();

  void dispose();
}

@FlutterApi()
abstract class ConnectivityFlutterApi {
  void onTransportChanged(ConnectivityTransportSnapshot snapshot);
}
