import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

abstract interface class ReconciliationPort {
  CancellableRequest<OfflineResult<OperationCompletion>> reconcile(ReconciliationRequest request);
}
