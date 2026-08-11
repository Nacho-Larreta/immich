import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

final class ConfirmedServerAccess {
  ConfirmedServerAccess({
    required this.apiEndpoint,
    required this.canonicalOrigin,
    required this.schemePolicy,
    required this.nativeContextGeneration,
    required this.confirmed,
    required this.fenced,
  }) {
    validateHttpEndpoint(apiEndpoint, 'apiEndpoint');
    validateHttpOrigin(canonicalOrigin, 'canonicalOrigin');
    validateEndpointSchemePolicy(canonicalOrigin, schemePolicy);
    if (apiEndpoint.origin != canonicalOrigin.origin) {
      throw ArgumentError.value(apiEndpoint, 'apiEndpoint', 'Must belong to the confirmed canonical origin');
    }
    if (nativeContextGeneration < 0) {
      throw ArgumentError.value(nativeContextGeneration, 'nativeContextGeneration', 'Must not be negative');
    }
  }

  final Uri apiEndpoint;
  final Uri canonicalOrigin;
  final EndpointSchemePolicy schemePolicy;
  final int nativeContextGeneration;
  final bool confirmed;
  final bool fenced;

  bool get isCurrent => confirmed && !fenced;

  bool matches({required Uri endpoint, required Uri origin, required EndpointSchemePolicy policy}) =>
      isCurrent && apiEndpoint == endpoint && canonicalOrigin == origin && schemePolicy == policy;

  @override
  bool operator ==(Object other) =>
      other is ConfirmedServerAccess &&
      other.apiEndpoint == apiEndpoint &&
      other.canonicalOrigin == canonicalOrigin &&
      other.schemePolicy == schemePolicy &&
      other.nativeContextGeneration == nativeContextGeneration &&
      other.confirmed == confirmed &&
      other.fenced == fenced;

  @override
  int get hashCode =>
      Object.hash(apiEndpoint, canonicalOrigin, schemePolicy, nativeContextGeneration, confirmed, fenced);
}
