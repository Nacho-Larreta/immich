import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

enum EndpointSchemePolicy { httpsOnly, explicitlyApprovedHttp, registeredLocalHttp }

EndpointSchemePolicy? parseEndpointSchemePolicy(String? value) {
  if (value == null) return null;
  for (final policy in EndpointSchemePolicy.values) {
    if (policy.name == value) return policy;
  }
  return null;
}

final class EndpointProbeRequest {
  EndpointProbeRequest({
    required this.candidateOrigin,
    required this.candidateApiEndpoint,
    required this.expectedUserId,
    required this.sessionEpoch,
    required this.probeGeneration,
    required this.schemePolicy,
  }) {
    validateHttpOrigin(candidateOrigin, 'candidateOrigin');
    _validateApiEndpoint(candidateApiEndpoint, candidateOrigin, 'candidateApiEndpoint');
    validateEndpointSchemePolicy(candidateOrigin, schemePolicy);
    if (expectedUserId.isEmpty) {
      throw ArgumentError.value(expectedUserId, 'expectedUserId', 'Must not be empty');
    }
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
  }

  final Uri candidateOrigin;
  final Uri candidateApiEndpoint;
  final String expectedUserId;
  final int sessionEpoch;
  final int probeGeneration;
  final EndpointSchemePolicy schemePolicy;
}

sealed class EndpointProbeResult {
  const EndpointProbeResult();

  factory EndpointProbeResult.validated({
    required Uri canonicalOrigin,
    required Uri apiEndpoint,
    required String userId,
    required EndpointSchemePolicy schemePolicy,
  }) = ValidatedEndpointProbeResult;
  const factory EndpointProbeResult.rejected(OfflineErrorCode error) = RejectedEndpointProbeResult;
}

final class ValidatedEndpointProbeResult extends EndpointProbeResult {
  ValidatedEndpointProbeResult({
    required this.canonicalOrigin,
    required this.apiEndpoint,
    required this.userId,
    required this.schemePolicy,
  }) {
    validateHttpOrigin(canonicalOrigin, 'canonicalOrigin');
    _validateApiEndpoint(apiEndpoint, canonicalOrigin, 'apiEndpoint');
    validateEndpointSchemePolicy(canonicalOrigin, schemePolicy);
    if (userId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'Must not be empty');
    }
  }

  final Uri canonicalOrigin;
  final Uri apiEndpoint;
  final String userId;
  final EndpointSchemePolicy schemePolicy;

  @override
  bool operator ==(Object other) {
    return other is ValidatedEndpointProbeResult &&
        other.canonicalOrigin == canonicalOrigin &&
        other.apiEndpoint == apiEndpoint &&
        other.userId == userId &&
        other.schemePolicy == schemePolicy;
  }

  @override
  int get hashCode => Object.hash(canonicalOrigin, apiEndpoint, userId, schemePolicy);
}

final class RejectedEndpointProbeResult extends EndpointProbeResult {
  const RejectedEndpointProbeResult(this.error);

  final OfflineErrorCode error;

  @override
  bool operator ==(Object other) => other is RejectedEndpointProbeResult && other.error == error;

  @override
  int get hashCode => error.hashCode;
}

final class EndpointActivationRequest {
  EndpointActivationRequest({required this.endpoint, required this.sessionEpoch, required this.probeGeneration}) {
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
  }

  final ValidatedEndpointProbeResult endpoint;
  final int sessionEpoch;
  final int probeGeneration;
}

final class EndpointActivationReceipt {
  EndpointActivationReceipt({required this.endpoint, required this.sessionEpoch, required this.probeGeneration}) {
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
  }

  final ValidatedEndpointProbeResult endpoint;
  final int sessionEpoch;
  final int probeGeneration;

  Uri get canonicalOrigin => endpoint.canonicalOrigin;
  Uri get confirmedEndpoint => endpoint.apiEndpoint;
  EndpointSchemePolicy get schemePolicy => endpoint.schemePolicy;
}

void _validateGeneration(int value, String argumentName) {
  if (value < 0) {
    throw ArgumentError.value(value, argumentName, 'Must not be negative');
  }
}

void validateEndpointSchemePolicy(Uri origin, EndpointSchemePolicy schemePolicy) {
  if (origin.scheme == 'https' && schemePolicy != EndpointSchemePolicy.httpsOnly) {
    throw ArgumentError.value(origin, 'canonicalOrigin', 'HTTPS requires the strict HTTPS policy');
  }
  if (origin.scheme == 'http' && schemePolicy == EndpointSchemePolicy.httpsOnly) {
    throw ArgumentError.value(origin, 'canonicalOrigin', 'HTTP requires an explicit approval');
  }
}

void _validateApiEndpoint(Uri apiEndpoint, Uri canonicalOrigin, String argumentName) {
  validateHttpEndpoint(apiEndpoint, argumentName);
  if (apiEndpoint.origin != canonicalOrigin.origin) {
    throw ArgumentError.value(apiEndpoint, argumentName, 'Must belong to the candidate origin');
  }
  final pathSegments = apiEndpoint.pathSegments.where((segment) => segment.isNotEmpty);
  if (pathSegments.isEmpty || pathSegments.last != 'api') {
    throw ArgumentError.value(apiEndpoint, argumentName, 'Must end in /api');
  }
}
