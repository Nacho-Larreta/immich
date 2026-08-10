import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';

abstract interface class ResolvedServerEndpointInstallerPort {
  Future<void> installResolvedServerEndpoint(DiscoveredServerEndpoint endpoint);
}
