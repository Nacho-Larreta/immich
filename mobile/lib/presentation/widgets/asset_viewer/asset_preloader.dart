import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';

class AssetPreloader {
  static final _dummyListener = ImageStreamListener((image, _) => image.dispose());

  final TimelineService timelineService;
  final bool Function() mounted;
  final LocalMediaPort<OwnedLocalMediaPayload> localMedia;
  final Duration delay;

  Timer? _timer;
  ImageStream? _prevStream;
  ImageStream? _nextStream;

  AssetPreloader({
    required this.timelineService,
    required this.mounted,
    required this.localMedia,
    this.delay = Durations.medium4,
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
      _prevStream = prev != null ? _resolveImage(prev, size) : null;
      _nextStream = next != null ? _resolveImage(next, size) : null;
    });
  }

  ImageStream _resolveImage(BaseAsset asset, Size size) {
    return getFullImageProvider(
      asset,
      localMedia: localMedia,
      localPolicy: LocalMediaPolicy.localOnly,
      size: size,
    ).resolve(ImageConfiguration.empty)..addListener(_dummyListener);
  }

  void dispose() {
    _timer?.cancel();
    _prevStream?.removeListener(_dummyListener);
    _nextStream?.removeListener(_dummyListener);
  }
}
