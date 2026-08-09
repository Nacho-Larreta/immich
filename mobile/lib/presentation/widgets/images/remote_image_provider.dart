import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/services/setting.service.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/presentation/widgets/images/animated_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/one_frame_multi_image_stream_completer.dart';
import 'package:openapi/api.dart';

final class RemoteImageProviderFactory {
  const RemoteImageProviderFactory({required this.media, required this.access, required this.endpoint});

  final RemoteMediaPort<OwnedRemoteMediaPayload> media;
  final RemoteMediaAccessSnapshot access;
  final RemoteMediaEndpointSnapshot endpoint;

  RemoteImageProvider image({required String url, required bool edited, required MediaRequestKind kind}) {
    return RemoteImageProvider(url: url, edited: edited, media: media, access: access, endpoint: endpoint, kind: kind);
  }

  RemoteImageProvider thumbnail({required String assetId, required String thumbhash, required bool edited}) {
    return RemoteImageProvider.thumbnail(
      assetId: assetId,
      thumbhash: thumbhash,
      edited: edited,
      media: media,
      access: access,
      endpoint: endpoint,
    );
  }

  RemoteFullImageProvider full({
    required String assetId,
    required String thumbhash,
    required AssetType assetType,
    required bool isAnimated,
    required bool edited,
  }) {
    return RemoteFullImageProvider(
      assetId: assetId,
      thumbhash: thumbhash,
      assetType: assetType,
      isAnimated: isAnimated,
      edited: edited,
      media: media,
      access: access,
      endpoint: endpoint,
    );
  }
}

class RemoteImageProvider extends CancellableImageProvider<RemoteImageProvider>
    with CancellableImageProviderMixin<RemoteImageProvider> {
  final String url;
  final bool edited;
  final RemoteMediaPort<OwnedRemoteMediaPayload> media;
  final RemoteMediaAccessSnapshot access;
  final RemoteMediaEndpointSnapshot endpoint;
  final MediaRequestKind kind;

  RemoteImageProvider({
    required String url,
    required this.edited,
    required this.media,
    required this.access,
    required this.endpoint,
    required this.kind,
  }) : url = _ownedRemoteMediaResource(endpoint, url);

  RemoteImageProvider.thumbnail({
    required String assetId,
    required String thumbhash,
    required this.edited,
    required this.media,
    required this.access,
    required this.endpoint,
  }) : kind = MediaRequestKind.thumbnail,
       url = endpoint
           .assetThumbnail(assetId, size: AssetMediaSize.thumbnail.value, thumbhash: thumbhash, edited: edited)
           .toString();

  @override
  Future<RemoteImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteImageProvider key, ImageDecoderCallback decode) {
    return OneFramePlaceholderImageStreamCompleter(
      _codec(key, decode),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('URL', key.url),
      ],
      onLastListenerRemoved: cancel,
    );
  }

  Stream<ImageInfo> _codec(RemoteImageProvider key, ImageDecoderCallback decode) {
    final request = this.request = RemoteImageRequest(
      media: key.media,
      uri: key.url,
      policy: key.access.policy,
      kind: key.kind,
    );
    return loadRequest(request, decode, isFinal: true);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is RemoteImageProvider) {
      return url == other.url &&
          edited == other.edited &&
          access == other.access &&
          endpoint == other.endpoint &&
          kind == other.kind &&
          identical(media, other.media);
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(url, edited, access, endpoint, kind, identityHashCode(media));
}

String _ownedRemoteMediaResource(RemoteMediaEndpointSnapshot endpoint, String url) {
  final resource = Uri.tryParse(url);
  if (resource == null || !endpoint.owns(resource)) {
    throw ArgumentError.value(url, 'url', 'Must belong to the captured remote media endpoint');
  }
  return resource.toString();
}

class RemoteFullImageProvider extends CancellableImageProvider<RemoteFullImageProvider>
    with CancellableImageProviderMixin<RemoteFullImageProvider> {
  final String assetId;
  final String thumbhash;
  final AssetType assetType;
  final bool isAnimated;
  final bool edited;
  final RemoteMediaPort<OwnedRemoteMediaPayload> media;
  final RemoteMediaAccessSnapshot access;
  final RemoteMediaEndpointSnapshot endpoint;

  RemoteFullImageProvider({
    required this.assetId,
    required this.thumbhash,
    required this.assetType,
    required this.isAnimated,
    required this.edited,
    required this.media,
    required this.access,
    required this.endpoint,
  });

  @override
  Future<RemoteFullImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(RemoteFullImageProvider key, ImageDecoderCallback decode) {
    if (key.isAnimated) {
      if (key.access.policy == RemoteMediaPolicy.cacheOnly) {
        return OneFramePlaceholderImageStreamCompleter(
          _offlineAnimatedCodec(key, decode),
          initialImage: getInitialImage(
            RemoteImageProvider.thumbnail(
              assetId: key.assetId,
              thumbhash: key.thumbhash,
              edited: key.edited,
              media: key.media,
              access: key.access,
              endpoint: key.endpoint,
            ),
          ),
          informationCollector: () => <DiagnosticsNode>[
            DiagnosticsProperty<ImageProvider>('Image provider', this),
            DiagnosticsProperty<String>('Asset Id', key.assetId),
            DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
          ],
          onLastListenerRemoved: cancel,
        );
      }
      return AnimatedImageStreamCompleter(
        stream: _animatedCodec(key, decode),
        scale: 1.0,
        initialImage: getInitialImage(
          RemoteImageProvider.thumbnail(
            assetId: key.assetId,
            thumbhash: key.thumbhash,
            edited: key.edited,
            media: key.media,
            access: key.access,
            endpoint: key.endpoint,
          ),
        ),
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<String>('Asset Id', key.assetId),
          DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
        ],
        onLastListenerRemoved: cancel,
      );
    }

    return OneFramePlaceholderImageStreamCompleter(
      _codec(key, decode),
      initialImage: getInitialImage(
        RemoteImageProvider.thumbnail(
          assetId: key.assetId,
          thumbhash: key.thumbhash,
          edited: key.edited,
          media: key.media,
          access: key.access,
          endpoint: key.endpoint,
        ),
      ),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Asset Id', key.assetId),
        DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
      ],
      onLastListenerRemoved: cancel,
    );
  }

  Stream<ImageInfo> _codec(RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();

    if (isCancelled) {
      return;
    }

    final previewRequest = request = RemoteImageRequest(
      media: key.media,
      uri: key.endpoint
          .assetThumbnail(key.assetId, size: AssetMediaSize.preview.value, thumbhash: key.thumbhash, edited: key.edited)
          .toString(),
      policy: key.access.policy,
      kind: MediaRequestKind.thumbnail,
    );
    final loadOriginal = assetType == AssetType.image && AppSetting.get(Setting.loadOriginal);
    yield* loadRequest(previewRequest, decode, isFinal: !loadOriginal);

    if (!loadOriginal) {
      return;
    }

    if (isCancelled) {
      return;
    }

    final originalRequest = request = RemoteImageRequest(
      media: key.media,
      uri: key.endpoint.assetOriginal(key.assetId, edited: key.edited).toString(),
      policy: key.access.policy,
      kind: MediaRequestKind.original,
    );
    yield* loadRequest(originalRequest, decode, isFinal: true);
  }

  @visibleForTesting
  Stream<ImageInfo> loadStaticMediaForTesting(ImageDecoderCallback decode) => _codec(this, decode);

  Stream<Object> _animatedCodec(RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();

    if (isCancelled) {
      return;
    }

    final previewRequest = request = RemoteImageRequest(
      media: key.media,
      uri: key.endpoint
          .assetThumbnail(key.assetId, size: AssetMediaSize.preview.value, thumbhash: key.thumbhash, edited: key.edited)
          .toString(),
      policy: key.access.policy,
      kind: MediaRequestKind.thumbnail,
    );
    yield* loadRequest(previewRequest, decode, isFinal: false);

    if (isCancelled) {
      return;
    }

    // always try original for animated, since previews don't support animation
    final originalRequest = request = RemoteImageRequest(
      media: key.media,
      uri: key.endpoint.assetOriginal(key.assetId, edited: key.edited).toString(),
      policy: key.access.policy,
      kind: MediaRequestKind.original,
    );
    final codec = await loadCodecRequest(originalRequest, isFinal: true);
    if (codec == null) {
      if (isCancelled) {
        return;
      }
      throw StateError('Failed to load animated codec for asset ${key.assetId}');
    }
    yield codec;
  }

  @visibleForTesting
  Stream<Object> loadAnimatedMediaForTesting(ImageDecoderCallback decode) {
    return access.policy == RemoteMediaPolicy.cacheOnly
        ? _offlineAnimatedCodec(this, decode)
        : _animatedCodec(this, decode);
  }

  Stream<ImageInfo> _offlineAnimatedCodec(RemoteFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();
    if (isCancelled) {
      return;
    }

    final previewRequest = request = RemoteImageRequest(
      media: key.media,
      uri: key.endpoint
          .assetThumbnail(key.assetId, size: AssetMediaSize.preview.value, thumbhash: key.thumbhash, edited: key.edited)
          .toString(),
      policy: key.access.policy,
      kind: MediaRequestKind.thumbnail,
    );
    yield* loadRequest(previewRequest, decode, isFinal: true);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is RemoteFullImageProvider) {
      return assetId == other.assetId &&
          thumbhash == other.thumbhash &&
          assetType == other.assetType &&
          isAnimated == other.isAnimated &&
          edited == other.edited &&
          access == other.access &&
          endpoint == other.endpoint &&
          identical(media, other.media);
    }

    return false;
  }

  @override
  int get hashCode =>
      Object.hash(assetId, thumbhash, assetType, isAnimated, edited, access, endpoint, identityHashCode(media));
}
