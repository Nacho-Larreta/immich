import 'package:immich_mobile/platform/remote_image_api.g.dart';

abstract interface class RemoteMediaHostApi {
  Future<RemoteImageResult> requestImage(RemoteImageRequest request);

  Future<void> cancelRequest(int requestId);

  Future<void> cancelAll();

  Future<void> dispose();
}

final class PigeonRemoteMediaHostApi implements RemoteMediaHostApi {
  PigeonRemoteMediaHostApi({RemoteImageApi? api}) : _api = api ?? RemoteImageApi();

  final RemoteImageApi _api;

  @override
  Future<RemoteImageResult> requestImage(RemoteImageRequest request) => _api.requestImage(request);

  @override
  Future<void> cancelRequest(int requestId) => _api.cancelRequest(requestId);

  @override
  Future<void> cancelAll() => _api.cancelAll();

  @override
  Future<void> dispose() => _api.dispose();
}
