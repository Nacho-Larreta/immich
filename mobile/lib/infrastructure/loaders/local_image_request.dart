part of 'image_request.dart';

class LocalImageRequest extends ImageRequest {
  final String localId;
  final int width;
  final int height;
  final AssetType assetType;

  LocalImageRequest({required this.localId, required ui.Size size, required this.assetType})
    : width = size.width.toInt(),
      height = size.height.toInt();

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final result = await localImageApi.requestImage(
      local_api.LocalImageRequest(
        assetId: localId,
        requestId: requestId,
        width: width,
        height: height,
        isVideo: assetType == AssetType.video,
        preferEncoded: false,
        policy: local_api.LocalImagePolicy.allowICloud,
        kind: local_api.LocalImageRequestKind.thumbnail,
      ),
    );
    final payload = _payloadFrom(result);
    if (payload == null) {
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
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) {
      return null;
    }

    final result = await localImageApi.requestImage(
      local_api.LocalImageRequest(
        assetId: localId,
        requestId: requestId,
        width: width,
        height: height,
        isVideo: assetType == AssetType.video,
        preferEncoded: true,
        policy: local_api.LocalImagePolicy.allowICloud,
        kind: local_api.LocalImageRequestKind.original,
      ),
    );
    final payload = _payloadFrom(result);
    if (payload == null) {
      return null;
    }

    final (codec, _) = switch (payload) {
      local_api.LocalImagePayload(pointer: final pointer, length: final length?) when pointer > 0 && length > 0 =>
        await _codecFromEncodedPlatformImage(pointer, length) ?? (null, null),
      _ => (_discardMalformedPayload(payload), null),
    };
    return codec;
  }

  @override
  Future<void> _onCancelled() {
    return localImageApi.cancelRequest(requestId);
  }

  local_api.LocalImagePayload? _payloadFrom(local_api.LocalImageResult result) {
    final payload = result.payload;
    if (payload == null || result.error != null) {
      if (payload != null) {
        _releaseNativeBuffer(payload.pointer);
      }
      return null;
    }
    return payload;
  }

  Null _discardMalformedPayload(local_api.LocalImagePayload payload) {
    _releaseNativeBuffer(payload.pointer);
    return null;
  }
}
