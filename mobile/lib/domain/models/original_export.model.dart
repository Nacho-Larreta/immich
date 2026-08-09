import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

enum LocalOriginalExportPolicy { localOnly, allowICloud }

enum OriginalExportError {
  assetMissing,
  mediaNotLocal,
  iCloudUnavailable,
  cancelled,
  timeout,
  unauthorized,
  wrongServer,
  serverUnavailable,
  httpFailure,
  storageUnavailable,
  writeFailed,
  cleanupFailed,
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

  factory OriginalExportResult.success(TemporaryFileLease lease) = OriginalExportSuccess;
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
  OriginalExportSuccess(this.lease) {
    if (lease.ownership != TemporaryFileOwnership.caller) {
      throw ArgumentError.value(lease.ownership, 'lease.ownership', 'Must be owned by the caller');
    }
  }

  final TemporaryFileLease lease;

  @override
  bool operator ==(Object other) => other is OriginalExportSuccess && identical(other.lease, lease);

  @override
  int get hashCode => identityHashCode(lease);
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
