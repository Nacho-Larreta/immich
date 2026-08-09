import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/presentation/widgets/images/animated_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/one_frame_multi_image_stream_completer.dart';
import 'package:immich_mobile/presentation/widgets/timeline/constants.dart';

class LocalThumbProvider extends CancellableImageProvider<LocalThumbProvider>
    with CancellableImageProviderMixin<LocalThumbProvider> {
  final String id;
  final Size size;
  final AssetType assetType;
  final LocalMediaPort<OwnedLocalMediaPayload> media;
  final LocalMediaPolicy policy;

  LocalThumbProvider({
    required this.id,
    required this.assetType,
    required this.media,
    required this.policy,
    this.size = kThumbnailResolution,
  });

  @override
  Future<LocalThumbProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(LocalThumbProvider key, ImageDecoderCallback decode) {
    return OneFramePlaceholderImageStreamCompleter(
      _codec(key, decode),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<String>('Id', key.id),
        DiagnosticsProperty<Size>('Size', key.size),
      ],
      onLastListenerRemoved: cancel,
    );
  }

  Stream<ImageInfo> _codec(LocalThumbProvider key, ImageDecoderCallback decode) {
    final request = this.request = LocalImageRequest(
      media: key.media,
      assetId: key.id,
      assetType: key.assetType,
      policy: key.policy,
      rendition: LocalMediaRendition.thumbnail(
        widthPx: max(1, key.size.width.ceil()),
        heightPx: max(1, key.size.height.ceil()),
      ),
    );
    return loadRequest(request, decode, isFinal: true);
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is LocalThumbProvider) {
      return id == other.id &&
          size == other.size &&
          assetType == other.assetType &&
          policy == other.policy &&
          identical(media, other.media);
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(id, size, assetType, policy, identityHashCode(media));
}

class LocalFullImageProvider extends CancellableImageProvider<LocalFullImageProvider>
    with CancellableImageProviderMixin<LocalFullImageProvider> {
  final String id;
  final Size size;
  final AssetType assetType;
  final bool isAnimated;
  final LocalMediaPort<OwnedLocalMediaPayload> media;
  final LocalMediaPolicy policy;

  LocalFullImageProvider({
    required this.id,
    required this.assetType,
    required this.size,
    required this.isAnimated,
    required this.media,
    required this.policy,
  });

  @override
  Future<LocalFullImageProvider> obtainKey(ImageConfiguration configuration) {
    return SynchronousFuture(this);
  }

  @override
  ImageStreamCompleter loadImage(LocalFullImageProvider key, ImageDecoderCallback decode) {
    if (key.isAnimated) {
      return AnimatedImageStreamCompleter(
        stream: _animatedCodec(key, decode),
        scale: 1.0,
        initialImage: getInitialImage(
          LocalThumbProvider(id: key.id, assetType: key.assetType, media: key.media, policy: key.policy),
        ),
        informationCollector: () => <DiagnosticsNode>[
          DiagnosticsProperty<ImageProvider>('Image provider', this),
          DiagnosticsProperty<String>('Id', key.id),
          DiagnosticsProperty<Size>('Size', key.size),
          DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
        ],
        onLastListenerRemoved: cancel,
      );
    }

    return OneFramePlaceholderImageStreamCompleter(
      _codec(key, decode),
      initialImage: getInitialImage(
        LocalThumbProvider(id: key.id, assetType: key.assetType, media: key.media, policy: key.policy),
      ),
      informationCollector: () => <DiagnosticsNode>[
        DiagnosticsProperty<ImageProvider>('Image provider', this),
        DiagnosticsProperty<String>('Id', key.id),
        DiagnosticsProperty<Size>('Size', key.size),
        DiagnosticsProperty<bool>('isAnimated', key.isAnimated),
      ],
      onLastListenerRemoved: cancel,
    );
  }

  Stream<ImageInfo> _codec(LocalFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();

    if (isCancelled) {
      return;
    }

    final loadOriginal = Store.get(StoreKey.loadOriginal, false);
    final devicePixelRatio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    var request = this.request = LocalImageRequest(
      media: key.media,
      assetId: key.id,
      assetType: key.assetType,
      policy: key.policy,
      rendition: LocalMediaRendition.thumbnail(
        widthPx: max(1, (size.width * devicePixelRatio).ceil()),
        heightPx: max(1, (size.height * devicePixelRatio).ceil()),
      ),
    );
    yield* loadRequest(request, decode, isFinal: !loadOriginal);

    if (!loadOriginal) {
      return;
    }

    if (isCancelled) {
      return;
    }

    request = this.request = LocalImageRequest(
      media: key.media,
      assetId: key.id,
      assetType: key.assetType,
      policy: key.policy,
      rendition: const LocalMediaRendition.originalEncoded(),
    );

    yield* loadRequest(request, decode, isFinal: true);
  }

  Stream<Object> _animatedCodec(LocalFullImageProvider key, ImageDecoderCallback decode) async* {
    yield* initialImageStream();

    if (isCancelled) {
      return;
    }

    final devicePixelRatio = PlatformDispatcher.instance.views.first.devicePixelRatio;
    yield* _loadAnimatedMedia(key, decode, devicePixelRatio: devicePixelRatio);
  }

  @visibleForTesting
  Stream<Object> loadAnimatedMediaForTesting(ImageDecoderCallback decode, {double devicePixelRatio = 1.0}) {
    return _loadAnimatedMedia(this, decode, devicePixelRatio: devicePixelRatio);
  }

  Stream<Object> _loadAnimatedMedia(
    LocalFullImageProvider key,
    ImageDecoderCallback decode, {
    required double devicePixelRatio,
  }) async* {
    final previewRequest = request = LocalImageRequest(
      media: key.media,
      assetId: key.id,
      assetType: key.assetType,
      policy: key.policy,
      rendition: LocalMediaRendition.thumbnail(
        widthPx: max(1, (size.width * devicePixelRatio).ceil()),
        heightPx: max(1, (size.height * devicePixelRatio).ceil()),
      ),
    );
    yield* loadRequest(previewRequest, decode, isFinal: false);

    if (isCancelled) {
      return;
    }

    // always try original for animated, since previews don't support animation
    final originalRequest = request = LocalImageRequest(
      media: key.media,
      assetId: key.id,
      assetType: key.assetType,
      policy: key.policy,
      rendition: const LocalMediaRendition.originalEncoded(),
    );
    final codec = await loadCodecRequest(originalRequest, isFinal: true);
    if (codec == null) {
      if (isCancelled) return;
      throw StateError('Failed to load animated codec for local asset ${key.id}');
    }
    yield codec;
  }

  @override
  bool operator ==(Object other) {
    if (identical(this, other)) return true;
    if (other is LocalFullImageProvider) {
      return id == other.id &&
          size == other.size &&
          assetType == other.assetType &&
          isAnimated == other.isAnimated &&
          policy == other.policy &&
          identical(media, other.media);
    }
    return false;
  }

  @override
  int get hashCode => Object.hash(id, size, assetType, isAnimated, policy, identityHashCode(media));
}
