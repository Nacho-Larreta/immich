import 'package:immich_mobile/platform/local_image_api.g.dart';

abstract interface class LocalMediaHostApi {
  Future<LocalImageResult> requestImage(LocalImageRequest request);

  Future<void> cancelRequest(int requestId);

  Future<void> cancelAll();

  Future<void> dispose();
}

final class PigeonLocalMediaHostApi implements LocalMediaHostApi {
  PigeonLocalMediaHostApi({LocalImageApi? api}) : _api = api ?? LocalImageApi();

  final LocalImageApi _api;

  @override
  Future<LocalImageResult> requestImage(LocalImageRequest request) => _api.requestImage(request);

  @override
  Future<void> cancelRequest(int requestId) => _api.cancelRequest(requestId);

  @override
  Future<void> cancelAll() => _api.cancelAll();

  @override
  Future<void> dispose() => _api.dispose();
}
