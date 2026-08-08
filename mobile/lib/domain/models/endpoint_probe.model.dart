import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

enum EndpointSchemePolicy { httpsOnly, approvedLocalHttp }

final class EndpointProbeRequest {
  EndpointProbeRequest({
    required this.candidateOrigin,
    required this.expectedUserId,
    required this.sessionEpoch,
    required this.probeGeneration,
    required this.schemePolicy,
  }) {
    validateHttpOrigin(candidateOrigin, 'candidateOrigin');
    if (candidateOrigin.scheme == 'http' && schemePolicy != EndpointSchemePolicy.approvedLocalHttp) {
      throw ArgumentError.value(candidateOrigin, 'candidateOrigin', 'HTTP requires an approved local exception');
    }
    if (expectedUserId.isEmpty) {
      throw ArgumentError.value(expectedUserId, 'expectedUserId', 'Must not be empty');
    }
    _validateGeneration(sessionEpoch, 'sessionEpoch');
    _validateGeneration(probeGeneration, 'probeGeneration');
  }

  final Uri candidateOrigin;
  final String expectedUserId;
  final int sessionEpoch;
  final int probeGeneration;
  final EndpointSchemePolicy schemePolicy;
}

sealed class EndpointProbeResult {
  const EndpointProbeResult();

  factory EndpointProbeResult.validated({
    required Uri canonicalOrigin,
    required String userId,
    required EndpointSchemePolicy schemePolicy,
  }) = ValidatedEndpointProbeResult;
  const factory EndpointProbeResult.rejected(OfflineErrorCode error) = RejectedEndpointProbeResult;
}

final class ValidatedEndpointProbeResult extends EndpointProbeResult {
  ValidatedEndpointProbeResult({required this.canonicalOrigin, required this.userId, required this.schemePolicy}) {
    validateHttpOrigin(canonicalOrigin, 'canonicalOrigin');
    _validateSchemePolicy(canonicalOrigin, schemePolicy);
    if (userId.isEmpty) {
      throw ArgumentError.value(userId, 'userId', 'Must not be empty');
    }
  }

  final Uri canonicalOrigin;
  final String userId;
  final EndpointSchemePolicy schemePolicy;

  @override
  bool operator ==(Object other) {
    return other is ValidatedEndpointProbeResult &&
        other.canonicalOrigin == canonicalOrigin &&
        other.userId == userId &&
        other.schemePolicy == schemePolicy;
  }

  @override
  int get hashCode => Object.hash(canonicalOrigin, userId, schemePolicy);
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
  EndpointActivationReceipt({required this.endpoint, required this.sessionEpoch}) {
    _validateGeneration(sessionEpoch, 'sessionEpoch');
  }

  final ValidatedEndpointProbeResult endpoint;
  final int sessionEpoch;

  Uri get confirmedEndpoint => endpoint.canonicalOrigin;
  EndpointSchemePolicy get schemePolicy => endpoint.schemePolicy;
}

void _validateGeneration(int value, String argumentName) {
  if (value < 0) {
    throw ArgumentError.value(value, argumentName, 'Must not be negative');
  }
}

void _validateSchemePolicy(Uri origin, EndpointSchemePolicy schemePolicy) {
  if (origin.scheme == 'http' && schemePolicy != EndpointSchemePolicy.approvedLocalHttp) {
    throw ArgumentError.value(origin, 'canonicalOrigin', 'HTTP requires an approved local exception');
  }
}
