import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';

typedef PreloadImageProviderFactory =
    ImageProvider Function(BaseAsset asset, Size size, RemoteImageProviderFactory remoteImages);

class AssetPreloader {
  static final _dummyListener = ImageStreamListener((image, _) => image.dispose());

  final TimelineService timelineService;
  final bool Function() mounted;
  final LocalMediaPort<OwnedLocalMediaPayload> localMedia;
  final RemoteImageProviderFactory Function() readRemoteImages;
  final Duration delay;
  final PreloadImageProviderFactory? imageProviderFactory;

  Timer? _timer;
  ImageStream? _prevStream;
  ImageStream? _nextStream;

  AssetPreloader({
    required this.timelineService,
    required this.mounted,
    required this.localMedia,
    required this.readRemoteImages,
    this.delay = Durations.medium4,
    this.imageProviderFactory,
  });

  void preload(int index, Size size) {
    unawaited(timelineService.preloadAssets(index));
    _timer?.cancel();
    _timer = Timer(delay, () async {
      if (!mounted()) return;
      final (prev, next) = await (
        timelineService.getAssetAsync(index - 1),
        timelineService.getAssetAsync(index + 1),
      ).wait;
      if (!mounted()) return;
      _prevStream?.removeListener(_dummyListener);
      _nextStream?.removeListener(_dummyListener);
      _prevStream = prev != null ? _resolveImage(prev, size, readRemoteImages()) : null;
      _nextStream = next != null ? _resolveImage(next, size, readRemoteImages()) : null;
    });
  }

  ImageStream _resolveImage(BaseAsset asset, Size size, RemoteImageProviderFactory remoteImages) {
    final provider =
        imageProviderFactory?.call(asset, size, remoteImages) ??
        getFullImageProvider(
          asset,
          localMedia: localMedia,
          localPolicy: LocalMediaPolicy.localOnly,
          remoteImages: remoteImages,
          size: size,
        );
    return provider.resolve(ImageConfiguration.empty)..addListener(_dummyListener);
  }

  void dispose() {
    _timer?.cancel();
    _prevStream?.removeListener(_dummyListener);
    _nextStream?.removeListener(_dummyListener);
  }
}
