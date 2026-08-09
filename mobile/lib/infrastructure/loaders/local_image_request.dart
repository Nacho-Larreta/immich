part of 'image_request.dart';

class LocalImageRequest extends ImageRequest {
  LocalImageRequest({
    required this.media,
    required this.assetId,
    required this.assetType,
    required this.policy,
    required this.rendition,
  });

  final LocalMediaPort<OwnedLocalMediaPayload> media;
  final String assetId;
  final AssetType assetType;
  final media_domain.LocalMediaPolicy policy;
  final media_domain.LocalMediaRendition rendition;
  CancellableMediaRequest<OwnedLocalMediaPayload>? _operation;

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final payload = await _requestPayload();
    if (payload == null) {
      return null;
    }

    try {
      final frame = switch (payload) {
        OwnedRgbaLocalMediaPayload(:final bytes, :final widthPx, :final heightPx, :final rowBytes) =>
          await _fromDecodedBytes(bytes, widthPx, heightPx, rowBytes),
        OwnedEncodedLocalMediaPayload(:final bytes) => await _fromEncodedBytes(bytes),
      };
      return frame == null ? null : ImageInfo(image: frame.image, scale: scale);
    } finally {
      payload.release();
    }
  }

  @override
  Future<ui.Codec?> loadCodec() async {
    if (_isCancelled) {
      return null;
    }

    final payload = await _requestPayload();
    if (payload == null) {
      return null;
    }
    try {
      if (payload is! OwnedEncodedLocalMediaPayload) {
        return null;
      }
      final result = await _codecFromEncodedBytes(payload.bytes);
      if (result == null) {
        return null;
      }
      final (codec, descriptor) = result;
      try {
        descriptor.dispose();
      } on Object {
        codec.dispose();
        rethrow;
      }
      return codec;
    } finally {
      payload.release();
    }
  }

  @override
  Future<void> _onCancelled() async {
    try {
      await _operation?.cancel();
    } on Object {
      return;
    }
  }

  Future<OwnedLocalMediaPayload?> _requestPayload() async {
    final operation = _operation = media.request(
      media_domain.LocalMediaRequest(
        requestId: requestId,
        assetId: assetId,
        assetType: assetType,
        policy: policy,
        rendition: rendition,
      ),
    );
    final result = await operation.result;
    _operation = null;
    if (_isCancelled) {
      result.valueOrNull?.release();
      return null;
    }
    return result.valueOrNull;
  }
}
