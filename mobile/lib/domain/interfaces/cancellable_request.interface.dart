import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

abstract interface class CancellableRequest<T> {
  Future<T> get result;

  Future<void> cancel();
}

abstract interface class CancellableMediaRequest<T> implements CancellableRequest<OfflineResult<T>> {
  Stream<MediaRequestProgress> get progress;
}
