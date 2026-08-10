import 'dart:convert';

import 'package:immich_mobile/domain/interfaces/anonymous_server_discovery.interface.dart';
import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';
import 'package:immich_mobile/utils/url_helper.dart';

final class AnonymousServerDiscoveryAdapter implements AnonymousServerDiscoveryPort {
  AnonymousServerDiscoveryAdapter({required this.transport, this.timeout = const Duration(seconds: 5)}) {
    if (timeout <= Duration.zero) {
      throw ArgumentError.value(timeout, 'timeout', 'Must be positive');
    }
  }

  final ProbeHttpTransportPort transport;
  final Duration timeout;

  @override
  Future<DiscoveredServerEndpoint> discover(String serverUrl) async {
    final candidate = _ServerCandidate.parse(serverUrl);
    final session = transport.openEphemeralSession(
      ProbeHttpSessionConfiguration(
        timeout: timeout,
        persistentCookiesEnabled: false,
        cacheEnabled: false,
        redirectPolicy: ProbeHttpRedirectPolicy.sameOriginOnly,
      ),
    );

    try {
      final discovery = await session
          .get(ProbeHttpRequest(uri: candidate.origin.resolve('/.well-known/immich')))
          .result;
      _requireSameOrigin(discovery, candidate.origin);
      final apiEndpoint = switch (discovery.statusCode) {
        200 => _readDiscoveredEndpoint(discovery.body, candidate.origin),
        404 => candidate.apiEndpoint,
        _ => throw const AnonymousServerDiscoveryException('Server discovery failed'),
      };

      final ping = await session.get(ProbeHttpRequest(uri: _appendPingPath(apiEndpoint))).result;
      _requireSameOrigin(ping, candidate.origin);
      if (ping.statusCode < 200 || ping.statusCode >= 300 || !_isImmichPing(ping.body)) {
        throw const AnonymousServerDiscoveryException('Server did not return a valid Immich ping');
      }
      return DiscoveredServerEndpoint(canonicalOrigin: candidate.origin, apiEndpoint: apiEndpoint);
    } finally {
      await session.close();
    }
  }
}

final class AnonymousServerDiscoveryException implements Exception {
  const AnonymousServerDiscoveryException(this.message);

  final String message;

  @override
  String toString() => 'AnonymousServerDiscoveryException: $message';
}

final class _ServerCandidate {
  const _ServerCandidate({required this.origin, required this.apiEndpoint});

  factory _ServerCandidate.parse(String serverUrl) {
    final parsed = Uri.parse(sanitizeUrl(serverUrl));
    validateHttpEndpoint(parsed, 'serverUrl');
    final origin = _canonicalOrigin(parsed);
    final pathSegments = parsed.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (pathSegments.isEmpty || pathSegments.last != 'api') {
      pathSegments.add('api');
    }
    return _ServerCandidate(
      origin: origin,
      apiEndpoint: Uri(
        scheme: origin.scheme,
        host: origin.host,
        port: origin.hasPort ? origin.port : null,
        pathSegments: pathSegments,
      ),
    );
  }

  final Uri origin;
  final Uri apiEndpoint;
}

Uri _canonicalOrigin(Uri uri) {
  final explicitPort =
      uri.hasPort && !((uri.scheme == 'http' && uri.port == 80) || (uri.scheme == 'https' && uri.port == 443));
  return Uri(scheme: uri.scheme, host: uri.host, port: explicitPort ? uri.port : null);
}

Uri _readDiscoveredEndpoint(String body, Uri origin) {
  final decoded = jsonDecode(body);
  if (decoded is! Map<String, dynamic>) {
    throw const AnonymousServerDiscoveryException('Malformed discovery document');
  }
  final api = decoded['api'];
  final endpointValue = api is Map<String, dynamic> ? api['endpoint'] : null;
  if (endpointValue is! String) {
    throw const AnonymousServerDiscoveryException('Discovery document has no API endpoint');
  }
  final endpoint = origin.resolve(endpointValue);
  validateHttpEndpoint(endpoint, 'discoveredEndpoint');
  if (endpoint.origin != origin.origin) {
    throw const AnonymousServerDiscoveryException('Discovered API endpoint changed origin');
  }
  final segments = endpoint.pathSegments.where((segment) => segment.isNotEmpty);
  if (segments.isEmpty || segments.last != 'api') {
    throw const AnonymousServerDiscoveryException('Discovered API endpoint must end in /api');
  }
  return endpoint;
}

void _requireSameOrigin(ProbeHttpResponse response, Uri origin) {
  final stayedOnOrigin =
      response.requestUri.origin == origin.origin &&
      response.effectiveUri.origin == origin.origin &&
      response.redirectChain.every((redirect) => redirect.origin == origin.origin);
  if (!stayedOnOrigin) {
    throw const AnonymousServerDiscoveryException('Server probe changed origin');
  }
}

Uri _appendPingPath(Uri apiEndpoint) {
  return apiEndpoint.replace(
    pathSegments: [...apiEndpoint.pathSegments.where((segment) => segment.isNotEmpty), 'server', 'ping'],
  );
}

bool _isImmichPing(String body) {
  final decoded = jsonDecode(body);
  return decoded is Map<String, dynamic> && decoded['res'] == 'pong';
}
