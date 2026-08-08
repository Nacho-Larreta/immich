import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';

abstract interface class RemoteMediaPort<T> {
  CancellableMediaRequest<T> request(RemoteMediaRequest request);
}
