import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';

final class RequestContextActivationLease {
  const RequestContextActivationLease(this.transportRevision);

  final int transportRevision;
}

abstract interface class RequestContextLeasePort {
  int get revision;

  RequestContextActivationLease? beginActivation(EndpointSchemePolicy policy);

  bool commitActivation(RequestContextActivationLease lease);

  bool isCurrent(RequestContextActivationLease lease);

  void abandonActivation(RequestContextActivationLease lease);

  bool invalidateForTransportReview();

  void invalidateAfterValidationFailure();
}
