part of 'image_request.dart';

final class RemoteMediaLoadFailure implements Exception {
  const RemoteMediaLoadFailure(this.code);

  final OfflineErrorCode code;

  @override
  String toString() => 'RemoteMediaLoadFailure(${code.name})';
}

class RemoteImageRequest extends ImageRequest {
  RemoteImageRequest({required this.media, required this.uri, required this.policy, required this.kind});

  final RemoteMediaPort<OwnedRemoteMediaPayload> media;
  final String uri;
  final media_domain.RemoteMediaPolicy policy;
  final media_domain.MediaRequestKind kind;
  CancellableMediaRequest<OwnedRemoteMediaPayload>? _operation;
  OfflineErrorCode? lastFailure;

  @override
  Future<ImageInfo?> load(ImageDecoderCallback decode, {double scale = 1.0}) async {
    if (_isCancelled) {
      return null;
    }

    final payload = await _requestPayload(preferEncoded: false);
    if (payload == null) {
      return null;
    }

    try {
      final frame = switch (payload) {
        OwnedEncodedRemoteMediaPayload(:final bytes) => await _fromEncodedBytes(bytes),
        OwnedRgbaRemoteMediaPayload(:final bytes, :final widthPx, :final heightPx, :final rowBytes) =>
          await _fromDecodedBytes(bytes, widthPx, heightPx, rowBytes),
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

    final payload = await _requestPayload(preferEncoded: true);
    if (payload == null) {
      return null;
    }
    try {
      if (payload is! OwnedEncodedRemoteMediaPayload) {
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

  Future<OwnedRemoteMediaPayload?> _requestPayload({required bool preferEncoded}) async {
    final resource = Uri.tryParse(uri);
    if (resource == null || !resource.hasAuthority || (resource.scheme != 'http' && resource.scheme != 'https')) {
      lastFailure = OfflineErrorCode.mediaUnavailable;
      throw const RemoteMediaLoadFailure(OfflineErrorCode.mediaUnavailable);
    }

    final operation = _operation = media.request(
      media_domain.RemoteMediaRequest(
        requestId: requestId,
        resource: resource,
        policy: policy,
        kind: kind,
        preferEncoded: preferEncoded,
      ),
    );
    final result = await operation.result;
    _operation = null;
    if (_isCancelled) {
      result.valueOrNull?.release();
      return null;
    }

    return switch (result) {
      OfflineSuccess<OwnedRemoteMediaPayload>(:final value) => value,
      OfflineFailure<OwnedRemoteMediaPayload>(error: OfflineErrorCode.cancelled) => null,
      OfflineFailure<OwnedRemoteMediaPayload>(:final error) => _throwFailure(error),
    };
  }

  Never _throwFailure(OfflineErrorCode error) {
    lastFailure = error;
    throw RemoteMediaLoadFailure(error);
  }
}
