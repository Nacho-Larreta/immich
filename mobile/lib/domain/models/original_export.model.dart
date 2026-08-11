import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

enum LocalOriginalExportPolicy { localOnly, allowICloud }

enum OriginalExportError {
  assetMissing,
  mediaNotLocal,
  iCloudUnavailable,
  cancelled,
  staleContext,
  timeout,
  unauthorized,
  wrongServer,
  serverUnavailable,
  httpFailure,
  storageUnavailable,
  writeFailed,
  cleanupFailed,
  leaseNotFound,
  platformUnsupported,
}

enum OriginalExportFailurePhase { admission, native, retry, adoption, presentation }

enum OriginalExportSessionRelation { current, generationAdvanced, sessionChanged, endpointChanged, unavailable }

final class OriginalExportFailureEvent {
  const OriginalExportFailureEvent({
    required this.phase,
    required this.errorCode,
    required this.attempt,
    required this.sessionRelation,
  });

  final OriginalExportFailurePhase phase;
  final OriginalExportError errorCode;
  final int attempt;
  final OriginalExportSessionRelation sessionRelation;
}

final class OriginalExportContextBinding {
  OriginalExportContextBinding({
    required this.sessionEpoch,
    required this.expectedContextGeneration,
    required this.apiEndpoint,
    required this.exactOrigin,
    required this.schemePolicy,
  }) {
    if (sessionEpoch < 0) {
      throw ArgumentError.value(sessionEpoch, 'sessionEpoch', 'Must not be negative');
    }
    if (expectedContextGeneration < 0) {
      throw ArgumentError.value(expectedContextGeneration, 'expectedContextGeneration', 'Must not be negative');
    }
    validateHttpEndpoint(apiEndpoint, 'apiEndpoint');
    validateHttpOrigin(exactOrigin, 'exactOrigin');
    validateEndpointSchemePolicy(exactOrigin, schemePolicy);
    if (apiEndpoint.origin != exactOrigin.origin) {
      throw ArgumentError.value(apiEndpoint, 'apiEndpoint', 'Must belong to the exact origin');
    }
  }

  final int sessionEpoch;
  final int expectedContextGeneration;
  final Uri apiEndpoint;
  final Uri exactOrigin;
  final EndpointSchemePolicy schemePolicy;

  bool sameSessionAndEndpoint(OriginalExportContextBinding other) {
    return sessionEpoch == other.sessionEpoch &&
        apiEndpoint == other.apiEndpoint &&
        exactOrigin == other.exactOrigin &&
        schemePolicy == other.schemePolicy;
  }

  @override
  bool operator ==(Object other) {
    return other is OriginalExportContextBinding &&
        other.sessionEpoch == sessionEpoch &&
        other.expectedContextGeneration == expectedContextGeneration &&
        other.apiEndpoint == apiEndpoint &&
        other.exactOrigin == exactOrigin &&
        other.schemePolicy == schemePolicy;
  }

  @override
  int get hashCode => Object.hash(sessionEpoch, expectedContextGeneration, apiEndpoint, exactOrigin, schemePolicy);
}

final class OriginalExportPresentationClaim {
  const OriginalExportPresentationClaim(this._claim);

  final bool Function() _claim;

  bool claim() => _claim();
}

final class LocalOriginalExportRequest {
  LocalOriginalExportRequest({required this.assetId, required this.suggestedFilename, required this.policy}) {
    _validateNonBlank(assetId, 'assetId');
    _validateNonBlank(suggestedFilename, 'suggestedFilename');
  }

  final String assetId;
  final String suggestedFilename;
  final LocalOriginalExportPolicy policy;

  @override
  bool operator ==(Object other) {
    return other is LocalOriginalExportRequest &&
        other.assetId == assetId &&
        other.suggestedFilename == suggestedFilename &&
        other.policy == policy;
  }

  @override
  int get hashCode => Object.hash(assetId, suggestedFilename, policy);
}

final class RemoteOriginalExportRequest {
  RemoteOriginalExportRequest({required this.resource, required this.suggestedFilename})
    : origin = Uri(scheme: resource.scheme, host: resource.host, port: resource.hasPort ? resource.port : null) {
    validateHttpResource(resource, 'resource');
    _validateNonBlank(suggestedFilename, 'suggestedFilename');
  }

  final Uri resource;
  final Uri origin;
  final String suggestedFilename;

  @override
  bool operator ==(Object other) {
    return other is RemoteOriginalExportRequest &&
        other.resource == resource &&
        other.suggestedFilename == suggestedFilename;
  }

  @override
  int get hashCode => Object.hash(resource, suggestedFilename);
}

sealed class OriginalExportResult {
  const OriginalExportResult();

  factory OriginalExportResult.success(TemporaryFileLease lease, {OriginalExportPresentationClaim? presentationClaim}) =
      OriginalExportSuccess;
  const factory OriginalExportResult.failure(OriginalExportError error) = OriginalExportFailure;

  TemporaryFileLease? get leaseOrNull => switch (this) {
    OriginalExportSuccess(:final lease) => lease,
    OriginalExportFailure() => null,
  };

  OriginalExportError? get errorOrNull => switch (this) {
    OriginalExportSuccess() => null,
    OriginalExportFailure(:final error) => error,
  };
}

final class OriginalExportSuccess extends OriginalExportResult {
  OriginalExportSuccess(this.lease, {this.presentationClaim}) {
    if (lease.ownership != TemporaryFileOwnership.caller) {
      throw ArgumentError.value(lease.ownership, 'lease.ownership', 'Must be owned by the caller');
    }
  }

  final TemporaryFileLease lease;
  final OriginalExportPresentationClaim? presentationClaim;

  @override
  bool operator ==(Object other) =>
      other is OriginalExportSuccess &&
      identical(other.lease, lease) &&
      identical(other.presentationClaim, presentationClaim);

  @override
  int get hashCode => Object.hash(identityHashCode(lease), identityHashCode(presentationClaim));
}

final class OriginalExportFailure extends OriginalExportResult {
  const OriginalExportFailure(this.error);

  final OriginalExportError error;

  @override
  bool operator ==(Object other) => other is OriginalExportFailure && other.error == error;

  @override
  int get hashCode => error.hashCode;
}

void _validateNonBlank(String value, String argumentName) {
  if (value.trim().isEmpty) {
    throw ArgumentError.value(value, argumentName, 'Must not be empty');
  }
}
