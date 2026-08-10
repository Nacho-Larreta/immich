part of 'image_request.dart';

final class LocalMediaLoadFailure implements Exception {
  const LocalMediaLoadFailure(this.code);

  final OfflineErrorCode code;

  @override
  String toString() => 'LocalMediaLoadFailure(${code.name})';
}

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
    final maxAttempts =
        policy == media_domain.LocalMediaPolicy.localOnly && rendition is media_domain.LocalMediaThumbnailRendition
        ? 2
        : 1;
    for (var attempt = 1; attempt <= maxAttempts; attempt++) {
      if (_isCancelled) {
        return null;
      }

      final operation = media.request(
        media_domain.LocalMediaRequest(
          requestId: requestId,
          assetId: assetId,
          assetType: assetType,
          policy: policy,
          rendition: rendition,
        ),
      );
      _operation = operation;
      final result = await operation.result;
      if (identical(_operation, operation)) {
        _operation = null;
      }
      if (_isCancelled) {
        result.valueOrNull?.release();
        return null;
      }

      switch (result) {
        case OfflineSuccess<OwnedLocalMediaPayload>(:final value):
          return value;
        case OfflineFailure<OwnedLocalMediaPayload>(:final error):
          if (attempt < maxAttempts && _isRetryableThumbnailFailure(error)) {
            continue;
          }
          throw LocalMediaLoadFailure(error);
      }
    }

    throw StateError('Local media request exhausted without a result');
  }

  bool _isRetryableThumbnailFailure(OfflineErrorCode error) =>
      error == OfflineErrorCode.timeout || error == OfflineErrorCode.mediaUnavailable;
}
