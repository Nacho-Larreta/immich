import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

final class BackupRunBinding {
  BackupRunBinding({
    required this.userId,
    required this.sessionEpoch,
    required this.probeGeneration,
    required this.nativeGeneration,
    required this.apiEndpoint,
    required this.canonicalOrigin,
    required this.schemePolicy,
    required this.transportRevision,
    required this.localLeaseRevision,
  }) {
    if (userId.isEmpty) throw ArgumentError.value(userId, 'userId', 'Must not be empty');
    for (final entry in {
      'sessionEpoch': sessionEpoch,
      'probeGeneration': probeGeneration,
      'nativeGeneration': nativeGeneration,
      'transportRevision': transportRevision,
      'localLeaseRevision': localLeaseRevision,
    }.entries) {
      if (entry.value < 0) throw ArgumentError.value(entry.value, entry.key, 'Must not be negative');
    }
    validateHttpEndpoint(apiEndpoint, 'apiEndpoint');
    validateHttpOrigin(canonicalOrigin, 'canonicalOrigin');
    validateEndpointSchemePolicy(canonicalOrigin, schemePolicy);
    if (apiEndpoint.origin != canonicalOrigin.origin) {
      throw ArgumentError.value(apiEndpoint, 'apiEndpoint', 'Must belong to canonicalOrigin');
    }
  }

  final String userId;
  final int sessionEpoch;
  final int probeGeneration;
  final int nativeGeneration;
  final Uri apiEndpoint;
  final Uri canonicalOrigin;
  final EndpointSchemePolicy schemePolicy;
  final int transportRevision;
  final int localLeaseRevision;

  String get digest => sha256.convert(utf8.encode(_canonicalValue)).toString();

  String get _canonicalValue => [
    userId,
    sessionEpoch,
    probeGeneration,
    nativeGeneration,
    apiEndpoint.toString(),
    canonicalOrigin.toString(),
    schemePolicy.name,
    transportRevision,
    localLeaseRevision,
  ].join('\u001f');

  @override
  bool operator ==(Object other) =>
      other is BackupRunBinding &&
      other.userId == userId &&
      other.sessionEpoch == sessionEpoch &&
      other.probeGeneration == probeGeneration &&
      other.nativeGeneration == nativeGeneration &&
      other.apiEndpoint == apiEndpoint &&
      other.canonicalOrigin == canonicalOrigin &&
      other.schemePolicy == schemePolicy &&
      other.transportRevision == transportRevision &&
      other.localLeaseRevision == localLeaseRevision;

  @override
  int get hashCode => Object.hash(
    userId,
    sessionEpoch,
    probeGeneration,
    nativeGeneration,
    apiEndpoint,
    canonicalOrigin,
    schemePolicy,
    transportRevision,
    localLeaseRevision,
  );
}

enum BackupRunBindingResolutionKind { current, temporarilyUnavailable, definitivelyStale }

final class BackupRunBindingResolution {
  const BackupRunBindingResolution.current(BackupRunBinding this.binding)
    : kind = BackupRunBindingResolutionKind.current;

  const BackupRunBindingResolution.temporarilyUnavailable()
    : kind = BackupRunBindingResolutionKind.temporarilyUnavailable,
      binding = null;

  const BackupRunBindingResolution.definitivelyStale()
    : kind = BackupRunBindingResolutionKind.definitivelyStale,
      binding = null;

  final BackupRunBindingResolutionKind kind;
  final BackupRunBinding? binding;
}
