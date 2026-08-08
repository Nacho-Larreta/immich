import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';

abstract interface class EndpointProbePort {
  CancellableRequest<EndpointProbeResult> probe(EndpointProbeRequest request);
}
