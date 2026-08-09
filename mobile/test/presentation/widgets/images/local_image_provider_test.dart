import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_preloader.dart';
import 'package:immich_mobile/presentation/widgets/images/local_image_provider.dart';

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
      }
      return event;
    });

    await expectLater(stream, emitsInOrder([isA<ImageInfo>(), emitsError(isA<StateError>())]));

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
    );

    preloader.preload(1, const Size(320, 180));
    await pumpEventQueue(times: 20);

    expect(port.requests, hasLength(2));
    expect(port.requests.every((request) => request.policy == LocalMediaPolicy.localOnly), isTrue);
    expect(port.requests.every((request) => request.rendition is LocalMediaThumbnailRendition), isTrue);
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
  _PreloadTimelineService({required this.previous, required this.next})
    : super((
        assetSource: (_, _) async => const <BaseAsset>[],
        bucketSource: () => const Stream.empty(),
        origin: TimelineOrigin.main,
      ));

  final BaseAsset previous;
  final BaseAsset next;

  @override
  Future<void> preloadAssets(int index) async {}

  @override
  Future<BaseAsset?> getAssetAsync(int index) async => switch (index) {
    0 => previous,
    2 => next,
    _ => null,
  };

  @override
  Future<void> dispose() async {}
}
