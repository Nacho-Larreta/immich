import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_preloader.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';

import '../../../fixtures/asset.stub.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('viewer emits allowICloud preview and original requests', () async {
    final port = _RecordingPort();
    final provider = LocalFullImageProvider(
      id: 'viewer-asset',
      assetType: AssetType.image,
      size: const Size(800, 600),
      isAnimated: true,
      media: port,
      policy: LocalMediaPolicy.allowICloud,
    );
    final stream = provider.loadAnimatedMediaForTesting(_unusedDecoder).map((event) {
      if (event case ImageInfo image) {
        image.dispose();
        return 'preview';
      }
      return event;
    });

    await expectLater(
      stream,
      emitsInOrder([
        'preview',
        emitsError(
          isA<LocalMediaLoadFailure>().having((failure) => failure.code, 'code', OfflineErrorCode.mediaUnavailable),
        ),
      ]),
    );

    expect(port.requests, isNotEmpty);
    expect(port.requests.every((request) => request.policy == LocalMediaPolicy.allowICloud), isTrue);
    expect(port.requests.any((request) => request.rendition is LocalMediaThumbnailRendition), isTrue);
    expect(port.requests.any((request) => request.rendition is LocalMediaOriginalEncodedRendition), isTrue);
  });

  test('asset preloader emits only localOnly requests', () async {
    final port = _RecordingPort();
    final timeline = _PreloadTimelineService(previous: LocalAssetStub.image1, next: LocalAssetStub.image2);
    final preloader = AssetPreloader(
      timelineService: timeline,
      mounted: () => true,
      localMedia: port,
      delay: Duration.zero,
      readRemoteImages: () => RemoteImageProviderFactory(
        media: _RemotePort(),
        access: const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 0),
        endpoint: _endpoint,
      ),
    );

    preloader.preload(1, const Size(320, 180));
    await pumpEventQueue(times: 20);

    expect(port.requests, hasLength(2));
    expect(port.requests.every((request) => request.policy == LocalMediaPolicy.localOnly), isTrue);
    expect(port.requests.every((request) => request.rendition is LocalMediaThumbnailRendition), isTrue);
    preloader.dispose();
    await timeline.dispose();
  });

  test('asset preloader reads a fresh remote snapshot after its delay', () async {
    final port = _RecordingPort();
    final remotePort = _RemotePort();
    final timeline = _PreloadTimelineService(previous: LocalAssetStub.image1, next: LocalAssetStub.image2);
    final snapshots = <RemoteMediaAccessSnapshot>[];
    var remoteImages = RemoteImageProviderFactory(
      media: remotePort,
      access: const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 4),
      endpoint: _endpoint,
    );
    final preloader = AssetPreloader(
      timelineService: timeline,
      mounted: () => true,
      localMedia: port,
      delay: Duration.zero,
      readRemoteImages: () => remoteImages,
      imageProviderFactory: (_, _, remoteImages) {
        snapshots.add(remoteImages.access);
        return MemoryImage(Uint8List.fromList(_transparentPixel));
      },
    );

    preloader.preload(1, const Size(320, 180));
    remoteImages = RemoteImageProviderFactory(
      media: remotePort,
      access: const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 5),
      endpoint: _endpoint,
    );
    await pumpEventQueue(times: 20);
    preloader.preload(1, const Size(320, 180));
    await pumpEventQueue(times: 20);

    expect(snapshots, [
      const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 5),
      const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 5),
      const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 5),
      const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 5),
    ]);
    preloader.dispose();
    await timeline.dispose();
  });

  test('asset preloader reads logged-out snapshot after asset lookup awaits', () async {
    final gate = Completer<void>();
    final timeline = _PreloadTimelineService(
      previous: LocalAssetStub.image1,
      next: LocalAssetStub.image2,
      lookupGate: gate,
    );
    final snapshots = <RemoteMediaAccessSnapshot>[];
    var remoteImages = RemoteImageProviderFactory(
      media: _RemotePort(),
      access: const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 8),
      endpoint: _endpoint,
    );
    final preloader = AssetPreloader(
      timelineService: timeline,
      mounted: () => true,
      localMedia: _RecordingPort(),
      delay: Duration.zero,
      readRemoteImages: () => remoteImages,
      imageProviderFactory: (_, _, remoteImages) {
        snapshots.add(remoteImages.access);
        return MemoryImage(Uint8List.fromList(_transparentPixel));
      },
    );

    preloader.preload(1, const Size(320, 180));
    await pumpEventQueue(times: 5);
    remoteImages = RemoteImageProviderFactory(
      media: _RemotePort(),
      access: const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 9),
      endpoint: _endpoint,
    );
    gate.complete();
    await pumpEventQueue(times: 20);

    expect(
      snapshots,
      List.filled(2, const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 9)),
    );
    preloader.dispose();
    await timeline.dispose();
  });

  test('last listener removal cancels the active local media handle', () async {
    final port = _PendingPort();
    final provider = LocalThumbProvider(
      id: 'cancel-asset',
      assetType: AssetType.image,
      media: port,
      policy: LocalMediaPolicy.localOnly,
      size: const Size(1, 1),
    );
    final completer = provider.loadImage(provider, _unusedDecoder);
    final listener = ImageStreamListener((_, _) {});

    completer.addListener(listener);
    await pumpEventQueue();
    completer.removeListener(listener);
    await pumpEventQueue();

    expect(port.operation.cancelCount, 1);
  });
}

Future<ui.Codec> _unusedDecoder(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
  throw StateError('unused');
}

final class _PendingPort implements LocalMediaPort<OwnedLocalMediaPayload> {
  final _Operation operation = _Operation();

  @override
  CancellableMediaRequest<OwnedLocalMediaPayload> request(LocalMediaRequest request) => operation;

  @override
  Future<void> cancelAll() async {}
}

final class _RemotePort implements RemoteMediaPort<OwnedRemoteMediaPayload> {
  @override
  CancellableMediaRequest<OwnedRemoteMediaPayload> request(RemoteMediaRequest request) {
    throw StateError('local-only preloader must not request remote media');
  }

  @override
  Future<void> cancelAll() async {}
}

final class _RecordingPort implements LocalMediaPort<OwnedLocalMediaPayload> {
  final List<LocalMediaRequest> requests = [];

  @override
  CancellableMediaRequest<OwnedLocalMediaPayload> request(LocalMediaRequest request) {
    requests.add(request);
    final result = switch (request.rendition) {
      LocalMediaThumbnailRendition() => OfflineResult<OwnedLocalMediaPayload>.success(
        OwnedRgbaLocalMediaPayload(
          lease: _BytesLease(Uint8List.fromList([0, 0, 0, 255])),
          widthPx: 1,
          heightPx: 1,
          rowBytes: 4,
        ),
      ),
      LocalMediaOriginalEncodedRendition() => const OfflineResult<OwnedLocalMediaPayload>.failure(
        OfflineErrorCode.mediaUnavailable,
      ),
    };
    return _Operation(result: result);
  }

  @override
  Future<void> cancelAll() async {}
}

final class _BytesLease implements LocalMediaPayloadLease {
  _BytesLease(this._bytes);

  final Uint8List _bytes;
  bool _released = false;

  @override
  Uint8List get bytes => _bytes;

  @override
  bool get isReleased => _released;

  @override
  void release() => _released = true;
}

final class _Operation implements CancellableMediaRequest<OwnedLocalMediaPayload> {
  _Operation({OfflineResult<OwnedLocalMediaPayload>? result}) {
    if (result != null) {
      _result.complete(result);
    }
  }

  final Completer<OfflineResult<OwnedLocalMediaPayload>> _result = Completer();
  int cancelCount = 0;

  @override
  Stream<MediaRequestProgress> get progress => const Stream.empty();

  @override
  Future<OfflineResult<OwnedLocalMediaPayload>> get result => _result.future;

  @override
  Future<void> cancel() async {
    cancelCount++;
    if (!_result.isCompleted) {
      _result.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    }
  }
}

final class _PreloadTimelineService extends TimelineService {
  _PreloadTimelineService({required this.previous, required this.next, this.lookupGate})
    : super((
        assetSource: (_, _) async => const <BaseAsset>[],
        bucketSource: () => const Stream.empty(),
        origin: TimelineOrigin.main,
      ));

  final BaseAsset previous;
  final BaseAsset next;
  final Completer<void>? lookupGate;

  @override
  Future<void> preloadAssets(int index) async {}

  @override
  Future<BaseAsset?> getAssetAsync(int index) async {
    await lookupGate?.future;
    return switch (index) {
      0 => previous,
      2 => next,
      _ => null,
    };
  }

  @override
  Future<void> dispose() async {}
}

final _endpoint = RemoteMediaEndpointSnapshot(Uri.parse('https://photos.test/api'));

const _transparentPixel = <int>[
  0x89,
  0x50,
  0x4E,
  0x47,
  0x0D,
  0x0A,
  0x1A,
  0x0A,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x48,
  0x44,
  0x52,
  0x00,
  0x00,
  0x00,
  0x01,
  0x00,
  0x00,
  0x00,
  0x01,
  0x08,
  0x06,
  0x00,
  0x00,
  0x00,
  0x1F,
  0x15,
  0xC4,
  0x89,
  0x00,
  0x00,
  0x00,
  0x0D,
  0x49,
  0x44,
  0x41,
  0x54,
  0x08,
  0xD7,
  0x63,
  0xF8,
  0xCF,
  0xC0,
  0xF0,
  0x1F,
  0x00,
  0x05,
  0x00,
  0x01,
  0xFF,
  0x89,
  0x99,
  0x3D,
  0x1D,
  0x00,
  0x00,
  0x00,
  0x00,
  0x49,
  0x45,
  0x4E,
  0x44,
  0xAE,
  0x42,
  0x60,
  0x82,
];
