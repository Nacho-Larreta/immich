import 'dart:async';

import 'package:flutter/material.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/images/image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';

typedef PreloadImageProviderFactory =
    ImageProvider Function(BaseAsset asset, Size size, RemoteImageProviderFactory remoteImages);

class AssetPreloader {
  final TimelineService timelineService;
  final bool Function() mounted;
  final LocalMediaPort<OwnedLocalMediaPayload> localMedia;
  final RemoteImageProviderFactory Function() readRemoteImages;
  final Duration delay;
  final PreloadImageProviderFactory? imageProviderFactory;
  final void Function(FlutterErrorDetails) reportError;

  Timer? _timer;
  ImageStream? _prevStream;
  ImageStream? _nextStream;
  ImageStreamListener? _prevListener;
  ImageStreamListener? _nextListener;
  int? _lastIndex;
  Size? _lastSize;
  RemoteMediaAccessSnapshot? _lastAccess;
  bool _cacheMissObserved = false;
  int _pipelineRevision = 0;

  AssetPreloader({
    required this.timelineService,
    required this.mounted,
    required this.localMedia,
    required this.readRemoteImages,
    this.delay = Durations.medium4,
    this.imageProviderFactory,
    void Function(FlutterErrorDetails)? reportError,
  }) : reportError = reportError ?? FlutterError.reportError;

  void preload(int index, Size size) {
    _lastIndex = index;
    _lastSize = size;
    final revision = ++_pipelineRevision;
    _own(timelineService.preloadAssets(index), revision, context: 'while warming the timeline');
    _timer?.cancel();
    _timer = Timer(delay, () => _own(_loadAdjacent(index, size, revision), revision));
  }

  void remoteAccessChanged(RemoteMediaAccessSnapshot access) {
    final previous = _lastAccess;
    _lastAccess = access;
    final becameNetworkCapable =
        access.policy == RemoteMediaPolicy.cacheThenNetwork &&
        (previous?.policy != RemoteMediaPolicy.cacheThenNetwork ||
            previous?.expectedContextGeneration != access.expectedContextGeneration);
    if (!_cacheMissObserved || !becameNetworkCapable) return;
    final index = _lastIndex;
    final size = _lastSize;
    if (index == null || size == null) return;
    _cacheMissObserved = false;
    _timer?.cancel();
    final revision = ++_pipelineRevision;
    _own(_loadAdjacent(index, size, revision), revision);
  }

  Future<void> _loadAdjacent(int index, Size size, int revision) async {
    if (!_isCurrent(revision)) return;
    final (prev, next) = await (
      timelineService.getAssetAsync(index - 1),
      timelineService.getAssetAsync(index + 1),
    ).wait;
    if (!_isCurrent(revision) || index != _lastIndex) return;
    _detachStreams();
    final remoteImages = readRemoteImages();
    _lastAccess = remoteImages.access;
    final previous = prev != null ? _resolveImage(prev, size, remoteImages) : null;
    _prevStream = previous?.$1;
    _prevListener = previous?.$2;
    final following = next != null ? _resolveImage(next, size, remoteImages) : null;
    _nextStream = following?.$1;
    _nextListener = following?.$2;
  }

  (ImageStream, ImageStreamListener) _resolveImage(
    BaseAsset asset,
    Size size,
    RemoteImageProviderFactory remoteImages,
  ) {
    final provider =
        imageProviderFactory?.call(asset, size, remoteImages) ??
        getFullImageProvider(
          asset,
          localMedia: localMedia,
          localPolicy: LocalMediaPolicy.localOnly,
          remoteImages: remoteImages,
          size: size,
        );
    final stream = provider.resolve(ImageConfiguration.empty);
    final listener = ImageStreamListener(
      (image, _) => image.dispose(),
      onError: (Object error, StackTrace? stackTrace) {
        if (error case RemoteMediaLoadFailure(code: OfflineErrorCode.cacheMiss)) {
          _cacheMissObserved = true;
          return;
        }
        reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'asset preloader',
            context: ErrorDescription('while preloading adjacent media'),
          ),
        );
      },
    );
    stream.addListener(listener);
    return (stream, listener);
  }

  void _own(Future<void> work, int revision, {String context = 'while preloading adjacent media'}) {
    unawaited(
      work.catchError((Object error, StackTrace stackTrace) {
        if (!_isCurrent(revision)) return;
        reportError(
          FlutterErrorDetails(
            exception: error,
            stack: stackTrace,
            library: 'asset preloader',
            context: ErrorDescription(context),
          ),
        );
      }),
    );
  }

  bool _isCurrent(int revision) => mounted() && revision == _pipelineRevision;

  void _detachStreams() {
    final prevListener = _prevListener;
    final nextListener = _nextListener;
    if (prevListener != null) _prevStream?.removeListener(prevListener);
    if (nextListener != null) _nextStream?.removeListener(nextListener);
    _prevStream = null;
    _nextStream = null;
    _prevListener = null;
    _nextListener = null;
  }

  void dispose() {
    _pipelineRevision++;
    _timer?.cancel();
    _detachStreams();
  }
}
