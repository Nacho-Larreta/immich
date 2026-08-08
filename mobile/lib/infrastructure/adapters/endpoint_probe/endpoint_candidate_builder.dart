import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

final class EndpointCandidateBuilder {
  const EndpointCandidateBuilder();

  List<EndpointProbeRequest> build({
    required Iterable<String> approvedEndpoints,
    required String? registeredLocalEndpoint,
    required String? currentWifiName,
    required String? preferredWifiName,
    required String expectedUserId,
    required int sessionEpoch,
    required int probeGeneration,
  }) {
    final candidates = <EndpointProbeRequest>[];
    final candidateEndpoints = <Uri>{};

    void addCandidate(Uri apiEndpoint, EndpointSchemePolicy schemePolicy) {
      if (!candidateEndpoints.add(apiEndpoint)) {
        return;
      }
      candidates.add(
        EndpointProbeRequest(
          candidateOrigin: _originOf(apiEndpoint),
          candidateApiEndpoint: apiEndpoint,
          expectedUserId: expectedUserId,
          sessionEpoch: sessionEpoch,
          probeGeneration: probeGeneration,
          schemePolicy: schemePolicy,
        ),
      );
    }

    if (_isPreferredWifi(currentWifiName, preferredWifiName)) {
      final localEndpoint = _canonicalApiEndpoint(registeredLocalEndpoint);
      if (localEndpoint != null) {
        addCandidate(localEndpoint, _policyFor(localEndpoint));
      }
    }

    for (final rawEndpoint in approvedEndpoints) {
      final endpoint = _canonicalApiEndpoint(rawEndpoint);
      if (endpoint == null || endpoint.scheme != 'https') {
        continue;
      }
      addCandidate(endpoint, EndpointSchemePolicy.httpsOnly);
    }

    return candidates;
  }
}

bool _isPreferredWifi(String? currentWifiName, String? preferredWifiName) {
  return preferredWifiName != null && preferredWifiName.isNotEmpty && currentWifiName == preferredWifiName;
}

EndpointSchemePolicy _policyFor(Uri endpoint) {
  return endpoint.scheme == 'http' ? EndpointSchemePolicy.approvedLocalHttp : EndpointSchemePolicy.httpsOnly;
}

Uri? _canonicalApiEndpoint(String? rawEndpoint) {
  if (rawEndpoint == null) {
    return null;
  }

  final endpoint = Uri.tryParse(rawEndpoint);
  if (endpoint == null) {
    return null;
  }

  try {
    validateHttpEndpoint(endpoint, 'endpoint');
  } on ArgumentError {
    return null;
  }

  final pathSegments = endpoint.pathSegments.toList();
  while (pathSegments.isNotEmpty && pathSegments.last.isEmpty) {
    pathSegments.removeLast();
  }
  if (pathSegments.isEmpty || pathSegments.last != 'api') {
    return null;
  }

  return Uri(scheme: endpoint.scheme, host: endpoint.host, port: _canonicalPort(endpoint), pathSegments: pathSegments);
}

int? _canonicalPort(Uri endpoint) {
  if (!endpoint.hasPort) {
    return null;
  }
  if ((endpoint.scheme == 'http' && endpoint.port == 80) || (endpoint.scheme == 'https' && endpoint.port == 443)) {
    return null;
  }
  return endpoint.port;
}

Uri _originOf(Uri endpoint) {
  return Uri(scheme: endpoint.scheme, host: endpoint.host, port: _canonicalPort(endpoint));
}
