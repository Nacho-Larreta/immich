import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';

abstract interface class AnonymousServerDiscoveryPort {
  Future<DiscoveredServerEndpoint> discover(String serverUrl);
}
