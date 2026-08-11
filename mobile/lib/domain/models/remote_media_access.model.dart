import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

final class RemoteMediaAccessSnapshot {
  const RemoteMediaAccessSnapshot({required this.policy, required this.sessionEpoch});

  final RemoteMediaPolicy policy;
  final int sessionEpoch;

  @override
  bool operator ==(Object other) =>
      other is RemoteMediaAccessSnapshot && other.policy == policy && other.sessionEpoch == sessionEpoch;

  @override
  int get hashCode => Object.hash(policy, sessionEpoch);
}

final class RemoteMediaEndpointSnapshot {
  RemoteMediaEndpointSnapshot(Uri apiEndpoint)
    : apiEndpoint = _normalizeApiEndpoint(apiEndpoint),
      canonicalOrigin = _canonicalOrigin(apiEndpoint);

  final Uri apiEndpoint;
  final Uri canonicalOrigin;

  Uri assetThumbnail(String assetId, {required String size, required bool edited, required String? thumbhash}) {
    return resource(
      ['assets', assetId, 'thumbnail'],
      queryParameters: {'size': size, 'edited': '$edited', if (thumbhash != null) 'c': thumbhash},
    );
  }

  Uri assetOriginal(String assetId, {required bool edited}) {
    return resource(['assets', assetId, 'original'], queryParameters: {'edited': '$edited'});
  }

  Uri resource(List<String> relativeSegments, {Map<String, String>? queryParameters}) {
    if (relativeSegments.any((segment) => segment.isEmpty || segment == '.' || segment == '..')) {
      throw ArgumentError.value(relativeSegments, 'relativeSegments', 'Must contain safe non-empty path segments');
    }
    return apiEndpoint.replace(
      pathSegments: [...apiEndpoint.pathSegments.where((segment) => segment.isNotEmpty), ...relativeSegments],
      queryParameters: queryParameters,
    );
  }

  bool owns(Uri resource) => _canonicalOrigin(resource) == canonicalOrigin;

  @override
  bool operator ==(Object other) => other is RemoteMediaEndpointSnapshot && other.apiEndpoint == apiEndpoint;

  @override
  int get hashCode => apiEndpoint.hashCode;
}

RemoteMediaAccessSnapshot mapRemoteMediaAccess(ReachabilityState state) {
  return RemoteMediaAccessSnapshot(
    policy: switch (state.phase) {
      ReachabilityPhase.online => RemoteMediaPolicy.cacheThenNetwork,
      ReachabilityPhase.probing when state.confirmedEndpoint != null => RemoteMediaPolicy.cacheThenNetwork,
      ReachabilityPhase.unknown ||
      ReachabilityPhase.probing ||
      ReachabilityPhase.offline ||
      ReachabilityPhase.paused ||
      ReachabilityPhase.disposed => RemoteMediaPolicy.cacheOnly,
    },
    sessionEpoch: state.sessionEpoch,
  );
}

Uri _normalizeApiEndpoint(Uri endpoint) {
  if (!endpoint.hasAuthority || (endpoint.scheme != 'http' && endpoint.scheme != 'https')) {
    throw ArgumentError.value(endpoint, 'apiEndpoint', 'Must be an absolute HTTP(S) endpoint');
  }
  if (endpoint.userInfo.isNotEmpty || endpoint.hasFragment || endpoint.hasQuery) {
    throw ArgumentError.value(endpoint, 'apiEndpoint', 'Must not include credentials, query, or fragment');
  }
  return endpoint.replace(path: endpoint.path.replaceFirst(RegExp(r'/+$'), ''));
}

Uri _canonicalOrigin(Uri resource) {
  if (!resource.hasAuthority || (resource.scheme != 'http' && resource.scheme != 'https')) {
    throw ArgumentError.value(resource, 'resource', 'Must be an absolute HTTP(S) URI');
  }
  final scheme = resource.scheme.toLowerCase();
  final defaultPort = scheme == 'https' ? 443 : 80;
  return Uri(
    scheme: scheme,
    host: resource.host.toLowerCase(),
    port: resource.port == defaultPort ? null : resource.port,
  );
}
