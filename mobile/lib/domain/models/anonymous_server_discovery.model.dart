import 'package:immich_mobile/domain/models/network_uri.model.dart';

final class DiscoveredServerEndpoint {
  DiscoveredServerEndpoint({required this.canonicalOrigin, required this.apiEndpoint}) {
    validateHttpOrigin(canonicalOrigin, 'canonicalOrigin');
    validateHttpEndpoint(apiEndpoint, 'apiEndpoint');
    if (apiEndpoint.origin != canonicalOrigin.origin) {
      throw ArgumentError.value(apiEndpoint, 'apiEndpoint', 'Must belong to the canonical origin');
    }
    final segments = apiEndpoint.pathSegments.where((segment) => segment.isNotEmpty);
    if (segments.isEmpty || segments.last != 'api') {
      throw ArgumentError.value(apiEndpoint, 'apiEndpoint', 'Must end in /api');
    }
  }

  final Uri canonicalOrigin;
  final Uri apiEndpoint;

  @override
  bool operator ==(Object other) {
    return other is DiscoveredServerEndpoint &&
        other.canonicalOrigin == canonicalOrigin &&
        other.apiEndpoint == apiEndpoint;
  }

  @override
  int get hashCode => Object.hash(canonicalOrigin, apiEndpoint);
}
