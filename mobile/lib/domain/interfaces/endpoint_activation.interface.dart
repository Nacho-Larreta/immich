import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

abstract interface class EndpointActivationPort {
  CancellableRequest<OfflineResult<EndpointActivationReceipt>> activate(EndpointActivationRequest request);
}
