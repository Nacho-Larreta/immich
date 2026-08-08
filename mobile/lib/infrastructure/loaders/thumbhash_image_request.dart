part of 'image_request.dart';

class ThumbhashImageRequest extends ImageRequest {
  final String thumbhash;

  ThumbhashImageRequest({required this.thumbhash});

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final result = await localImageApi.getThumbhash(
      local_api.LocalImageThumbhashRequest(thumbhash: thumbhash, requestId: requestId),
    );
    final payload = result.payload;
    if (payload == null || result.error != null) {
      if (payload != null) {
        _releaseNativeBuffer(payload.pointer);
      }
      return null;
    }

    final frame = switch (payload) {
      local_api.LocalImagePayload(
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
  Future<ui.Codec?> loadCodec() => throw UnsupportedError('Thumbhash does not support codec loading');

  @override
  void _onCancelled() {}

  Null _discardMalformedPayload(local_api.LocalImagePayload payload) {
    _releaseNativeBuffer(payload.pointer);
    return null;
  }
}
