part of 'image_request.dart';

class RemoteImageRequest extends ImageRequest {
  final String uri;

  RemoteImageRequest({required this.uri});

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final request = _request(preferEncoded: false, kind: remote_api.RemoteImageRequestKind.thumbnail);
    if (request == null) {
      return null;
    }

    final result = await remoteImageApi.requestImage(request);
    final payload = _payloadFrom(result);
    if (payload == null) {
      return null;
    }

    // Android always returns encoded data, so we need to check for both shapes of the response.
    final frame = switch (payload) {
      remote_api.RemoteImagePayload(pointer: final pointer, length: final length?) when pointer > 0 && length > 0 =>
        await _fromEncodedPlatformImage(pointer, length),
      remote_api.RemoteImagePayload(
        pointer: final pointer,
        width: final width?,
        height: final height?,
        rowBytes: final rowBytes?,
      )
          when pointer > 0 && width > 0 && height > 0 && rowBytes >= width * 4 =>
        await _fromDecodedPlatformImage(pointer, width, height, rowBytes),
      _ => _discardMalformedPayload(payload),
    };
    return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) {
      return null;
    }

    final request = _request(preferEncoded: true, kind: remote_api.RemoteImageRequestKind.original);
    if (request == null) {
      return null;
    }

    final result = await remoteImageApi.requestImage(request);
    final payload = _payloadFrom(result);
    if (payload == null) {
      return null;
    }

    final (codec, _) = switch (payload) {
      remote_api.RemoteImagePayload(pointer: final pointer, length: final length?) when pointer > 0 && length > 0 =>
        await _codecFromEncodedPlatformImage(pointer, length) ?? (null, null),
      _ => (_discardMalformedPayload(payload), null),
    };
    return codec;
  }

  @override
  Future<void> _onCancelled() {
    return remoteImageApi.cancelRequest(requestId);
  }

  remote_api.RemoteImageRequest? _request({
    required bool preferEncoded,
    required remote_api.RemoteImageRequestKind kind,
  }) {
    final parsedUri = Uri.tryParse(uri);
    if (parsedUri == null || !parsedUri.hasAuthority || (parsedUri.scheme != 'http' && parsedUri.scheme != 'https')) {
      return null;
    }

    return remote_api.RemoteImageRequest(
      url: uri,
      origin: parsedUri.origin,
      requestId: requestId,
      preferEncoded: preferEncoded,
      policy: remote_api.RemoteImagePolicy.cacheThenNetwork,
      kind: kind,
    );
  }

  remote_api.RemoteImagePayload? _payloadFrom(remote_api.RemoteImageResult result) {
    final payload = result.payload;
    if (payload == null || result.error != null) {
      if (payload != null) {
        _releaseNativeBuffer(payload.pointer);
      }
      return null;
    }
    return payload;
  }

  Null _discardMalformedPayload(remote_api.RemoteImagePayload payload) {
    _releaseNativeBuffer(payload.pointer);
    return null;
  }
}
