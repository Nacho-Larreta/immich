import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

abstract interface class EndpointProbeCyclePort {
  CancellableRequest<EndpointProbeResult> begin(ReachabilityIdentity identity);
}
