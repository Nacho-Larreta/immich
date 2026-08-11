import 'dart:async';
import 'dart:ui' as ui;

import 'package:drift/drift.dart' hide isNotNull, isNull;
import 'package:drift/native.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/services/setting.service.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/presentation/widgets/images/thumbnail.widget.dart';
import 'package:logging/logging.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Drift db;
  setUpAll(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });
  tearDownAll(() => db.close());

  test('thumbnail key includes origin, kind, policy, epoch, edited flag, and port identity', () {
    final firstPort = _Port();
    final secondPort = _Port();
    const offline = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 3);
    const online = RemoteMediaAccessSnapshot(
      policy: RemoteMediaPolicy.cacheThenNetwork,
      sessionEpoch: 3,
      expectedContextGeneration: 3,
    );
    const relogged = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 4);

    final base = _image(firstPort, offline);
    final same = _image(firstPort, offline);

    expect(base, same);
    expect(base.hashCode, same.hashCode);
    expect(base, isNot(_image(firstPort, offline, edited: false)));
    expect(base, isNot(_image(firstPort, online)));
    expect(
      _image(firstPort, online),
      isNot(
        _image(
          firstPort,
          const RemoteMediaAccessSnapshot(
            policy: RemoteMediaPolicy.cacheThenNetwork,
            sessionEpoch: 3,
            expectedContextGeneration: 4,
          ),
        ),
      ),
    );
    expect(base, isNot(_image(firstPort, relogged)));
    expect(base, isNot(_image(secondPort, offline)));
    expect(base, isNot(_image(firstPort, offline, endpoint: _otherEndpoint)));
    expect(base, isNot(_image(firstPort, offline, kind: MediaRequestKind.original)));
  });

  test('full key includes asset type in addition to snapshot and port identity', () {
    final port = _Port();
    const access = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 1);
    final image = _full(port, access, assetType: AssetType.image);
    final same = _full(port, access, assetType: AssetType.image);
    final video = _full(port, access, assetType: AssetType.video);

    expect(image, same);
    expect(image.hashCode, same.hashCode);
    expect(image, isNot(video));
    expect(
      image,
      isNot(
        _full(
          port,
          const RemoteMediaAccessSnapshot(
            policy: RemoteMediaPolicy.cacheThenNetwork,
            sessionEpoch: 1,
            expectedContextGeneration: 1,
          ),
          assetType: AssetType.image,
        ),
      ),
    );
    expect(
      image,
      isNot(
        _full(
          port,
          const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 2),
          assetType: AssetType.image,
        ),
      ),
    );
    expect(image, isNot(_full(_Port(), access, assetType: AssetType.image)));
  });

  test('offline to online and relogin build new keys and issue isolated requests', () async {
    final port = _Port(result: const OfflineResult.failure(OfflineErrorCode.cacheMiss));
    const offline = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 9);
    const online = RemoteMediaAccessSnapshot(
      policy: RemoteMediaPolicy.cacheThenNetwork,
      sessionEpoch: 9,
      expectedContextGeneration: 9,
    );
    const relogged = RemoteMediaAccessSnapshot(
      policy: RemoteMediaPolicy.cacheThenNetwork,
      sessionEpoch: 10,
      expectedContextGeneration: 10,
    );

    final providers = [_image(port, offline), _image(port, online), _image(port, relogged)];

    for (final provider in providers) {
      await expectLater(provider.loadForTesting(_unusedDecoder), emitsError(isA<RemoteMediaLoadFailure>()));
    }

    expect(port.requests.map((request) => request.policy), [
      RemoteMediaPolicy.cacheOnly,
      RemoteMediaPolicy.cacheThenNetwork,
      RemoteMediaPolicy.cacheThenNetwork,
    ]);
    expect(providers.toSet(), hasLength(3));
  });

  test('cache miss terminates with a typed error and last-listener removal cancels active work', () async {
    final cacheMissPort = _Port(result: const OfflineResult.failure(OfflineErrorCode.cacheMiss));
    const access = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 2);
    final cacheMissProvider = _image(cacheMissPort, access);

    await expectLater(
      cacheMissProvider.loadForTesting(_unusedDecoder),
      emitsError(isA<RemoteMediaLoadFailure>().having((failure) => failure.code, 'code', OfflineErrorCode.cacheMiss)),
    );

    final pendingPort = _Port();
    final pendingProvider = _image(pendingPort, access, url: 'https://photos.test/pending');
    final completer = pendingProvider.loadImage(pendingProvider, _unusedDecoder);
    final listener = ImageStreamListener((_, _) {});
    completer.addListener(listener);
    await pumpEventQueue();
    completer.removeListener(listener);
    await pumpEventQueue();

    expect(pendingPort.operations.single.cancelCount, 1);
  });

  testWidgets('cache miss preserves the thumbnail placeholder without severe logging', (tester) async {
    final port = _Port(result: const OfflineResult.failure(OfflineErrorCode.cacheMiss));
    const access = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 2);
    final provider = _image(port, access);
    final severeRecords = <LogRecord>[];
    final previousLevel = Logger.root.level;
    Logger.root.level = Level.ALL;
    final subscription = Logger.root.onRecord.where((record) => record.level >= Level.SEVERE).listen(severeRecords.add);
    addTearDown(() async {
      await subscription.cancel();
      Logger.root.level = previousLevel;
    });

    await tester.pumpWidget(
      MaterialApp(
        home: SizedBox.square(
          dimension: 64,
          child: Thumbnail(
            imageProvider: provider,
            thumbhashProvider: MemoryImage(Uint8List.fromList(_transparentPixel)),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    expect(tester.takeException(), isNull);
    expect(severeRecords, isEmpty);
    expect(find.byType(Thumbnail), findsOneWidget);
  });

  testWidgets('visible cache miss retries with network policy when access becomes online', (tester) async {
    final access = ValueNotifier(const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 2));
    addTearDown(access.dispose);
    final port = _Port(
      results: [const OfflineResult.failure(OfflineErrorCode.cacheMiss), OfflineResult.success(_rgbaPayload())],
    );

    await tester.pumpWidget(
      MaterialApp(
        home: ValueListenableBuilder<RemoteMediaAccessSnapshot>(
          valueListenable: access,
          builder: (_, snapshot, _) => SizedBox.square(
            dimension: 64,
            child: Thumbnail(
              imageProvider: _image(port, snapshot),
              thumbhashProvider: MemoryImage(Uint8List.fromList(_transparentPixel)),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();

    access.value = const RemoteMediaAccessSnapshot(
      policy: RemoteMediaPolicy.cacheThenNetwork,
      sessionEpoch: 2,
      expectedContextGeneration: 2,
    );
    await tester.pumpAndSettle();

    expect(port.requests.map((request) => request.policy), [
      RemoteMediaPolicy.cacheOnly,
      RemoteMediaPolicy.cacheThenNetwork,
    ]);
  });

  test('animated cache miss terminates and propagates edited to offline requests', () async {
    final port = _Port(result: const OfflineResult.failure(OfflineErrorCode.cacheMiss));
    const access = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 6);
    final provider = RemoteFullImageProvider(
      assetId: 'animated-1',
      thumbhash: 'hash',
      assetType: AssetType.image,
      isAnimated: true,
      edited: false,
      media: port,
      access: access,
      endpoint: _endpoint,
    );

    await expectLater(provider.loadAnimatedMediaForTesting(_unusedDecoder), emitsError(isA<RemoteMediaLoadFailure>()));

    expect(port.requests, hasLength(1));
    expect(port.requests.single.policy, RemoteMediaPolicy.cacheOnly);
    expect(port.requests.single.resource.queryParameters['edited'], 'false');

    final errors = <Object>[];
    final completer = provider.loadImage(provider, _unusedDecoder);
    final listener = ImageStreamListener((_, _) {}, onError: (Object error, _) => errors.add(error));
    completer.addListener(listener);
    await pumpEventQueue(times: 20);

    expect(errors, hasLength(1));
    expect(errors.single, isA<RemoteMediaLoadFailure>());
    expect(port.requests, hasLength(3));
    expect(port.requests.every((request) => request.resource.queryParameters['edited'] == 'false'), isTrue);
    completer.removeListener(listener);
  });

  test('same asset snapshot on different origins creates isolated keys and URLs', () {
    final port = _Port();
    const access = RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 4);
    final first = RemoteImageProviderFactory(
      media: port,
      access: access,
      endpoint: _endpoint,
    ).thumbnail(assetId: 'asset-1', thumbhash: 'hash', edited: true);
    final second = RemoteImageProviderFactory(
      media: port,
      access: access,
      endpoint: _otherEndpoint,
    ).thumbnail(assetId: 'asset-1', thumbhash: 'hash', edited: true);

    expect(first, isNot(second));
    expect(Uri.parse(first.url).host, 'photos.test');
    expect(Uri.parse(second.url).host, 'other.test');

    final firstFull = RemoteImageProviderFactory(
      media: port,
      access: access,
      endpoint: _endpoint,
    ).full(assetId: 'asset-1', thumbhash: 'hash', assetType: AssetType.video, isAnimated: false, edited: true);
    final secondFull = RemoteImageProviderFactory(
      media: port,
      access: access,
      endpoint: _otherEndpoint,
    ).full(assetId: 'asset-1', thumbhash: 'hash', assetType: AssetType.video, isAnimated: false, edited: true);
    expect(firstFull, isNot(secondFull));
  });

  test('static full provider marks preview thumbnail and original explicitly', () async {
    await AppSetting.set(Setting.loadOriginal, true);
    addTearDown(() => AppSetting.set(Setting.loadOriginal, false));
    final port = _Port(
      results: [OfflineResult.success(_rgbaPayload()), const OfflineResult.failure(OfflineErrorCode.cacheMiss)],
    );
    final provider = _full(
      port,
      const RemoteMediaAccessSnapshot(
        policy: RemoteMediaPolicy.cacheThenNetwork,
        sessionEpoch: 1,
        expectedContextGeneration: 1,
      ),
      assetType: AssetType.image,
    );

    await expectLater(
      provider.loadStaticMediaForTesting(_unusedDecoder).map((image) {
        image.dispose();
        return image;
      }),
      emitsInOrder([isA<ImageInfo>(), emitsError(isA<RemoteMediaLoadFailure>())]),
    );

    expect(port.requests.map((request) => request.kind), [MediaRequestKind.thumbnail, MediaRequestKind.original]);
    expect(port.requests.first.resource.path, '/api/assets/asset-1/thumbnail');
    expect(port.requests.last.resource.path, '/api/assets/asset-1/original');
  });

  test('animated full provider marks preview thumbnail and encoded original explicitly', () async {
    final port = _Port(
      results: [OfflineResult.success(_rgbaPayload()), const OfflineResult.failure(OfflineErrorCode.cacheMiss)],
    );
    final provider = RemoteFullImageProvider(
      assetId: 'animated-kind',
      thumbhash: 'hash',
      assetType: AssetType.image,
      isAnimated: true,
      edited: true,
      media: port,
      access: const RemoteMediaAccessSnapshot(
        policy: RemoteMediaPolicy.cacheThenNetwork,
        sessionEpoch: 1,
        expectedContextGeneration: 1,
      ),
      endpoint: _endpoint,
    );

    await expectLater(
      provider.loadAnimatedMediaForTesting(_unusedDecoder).map((event) {
        if (event case ImageInfo image) image.dispose();
        return event;
      }),
      emitsInOrder([isA<ImageInfo>(), emitsError(isA<RemoteMediaLoadFailure>())]),
    );

    expect(port.requests.map((request) => request.kind), [MediaRequestKind.thumbnail, MediaRequestKind.original]);
    expect(port.requests.last.preferEncoded, isTrue);
  });

  for (final animated in [false, true]) {
    testWidgets('cache miss evicts ${animated ? 'animated' : 'static'} full provider from pending and live cache', (
      tester,
    ) async {
      final cache = PaintingBinding.instance.imageCache..clear();
      final baseline = cache.pendingImageCount;
      final provider = RemoteFullImageProvider(
        assetId: 'cache-miss-${animated ? 'animated' : 'static'}',
        thumbhash: 'hash',
        assetType: animated ? AssetType.image : AssetType.video,
        isAnimated: animated,
        edited: true,
        media: _Port(result: const OfflineResult.failure(OfflineErrorCode.cacheMiss)),
        access: const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 1),
        endpoint: _endpoint,
      );

      final error = await _resolveError(provider);
      await tester.pump();

      expect(error, isA<RemoteMediaLoadFailure>());
      expect(cache.pendingImageCount, baseline);
      expect(cache.statusForKey(provider).pending, isFalse);
      expect(cache.statusForKey(provider).live, isFalse);
    });
  }

  testWidgets('cache miss evicts thumbnail provider from pending and live cache', (tester) async {
    final cache = PaintingBinding.instance.imageCache..clear();
    final baseline = cache.pendingImageCount;
    final provider = _image(
      _Port(result: const OfflineResult.failure(OfflineErrorCode.cacheMiss)),
      const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheOnly, sessionEpoch: 1),
    );

    final error = await _resolveError(provider);
    await tester.pump();

    expect(error, isA<RemoteMediaLoadFailure>());
    expect(cache.pendingImageCount, baseline);
    expect(cache.statusForKey(provider).pending, isFalse);
    expect(cache.statusForKey(provider).live, isFalse);
  });
}

final _endpoint = RemoteMediaEndpointSnapshot(Uri.parse('https://photos.test/api'));
final _otherEndpoint = RemoteMediaEndpointSnapshot(Uri.parse('https://other.test/api'));

RemoteImageProvider _image(
  RemoteMediaPort<OwnedRemoteMediaPayload> port,
  RemoteMediaAccessSnapshot access, {
  bool edited = true,
  String url = 'https://photos.test/image',
  RemoteMediaEndpointSnapshot? endpoint,
  MediaRequestKind kind = MediaRequestKind.thumbnail,
}) {
  final capturedEndpoint = endpoint ?? _endpoint;
  return RemoteImageProvider(
    url: capturedEndpoint == _otherEndpoint ? 'https://other.test/image' : url,
    edited: edited,
    media: port,
    access: access,
    endpoint: capturedEndpoint,
    kind: kind,
  );
}

Future<Object> _resolveError(ImageProvider provider) async {
  final error = Completer<Object>();
  final stream = provider.resolve(ImageConfiguration.empty);
  late final ImageStreamListener listener;
  listener = ImageStreamListener((image, _) => image.dispose(), onError: (Object value, _) => error.complete(value));
  stream.addListener(listener);
  final result = await error.future.timeout(const Duration(seconds: 2));
  stream.removeListener(listener);
  return result;
}

OwnedRgbaRemoteMediaPayload _rgbaPayload() => OwnedRgbaRemoteMediaPayload(
  lease: _Lease(Uint8List.fromList([0, 0, 0, 255])),
  widthPx: 1,
  heightPx: 1,
  rowBytes: 4,
);

RemoteFullImageProvider _full(
  RemoteMediaPort<OwnedRemoteMediaPayload> port,
  RemoteMediaAccessSnapshot access, {
  required AssetType assetType,
}) {
  return RemoteFullImageProvider(
    assetId: 'asset-1',
    thumbhash: 'hash',
    assetType: assetType,
    isAnimated: false,
    edited: true,
    media: port,
    access: access,
    endpoint: _endpoint,
  );
}

Future<ui.Codec> _unusedDecoder(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
  throw StateError('unused');
}

final class _Port implements RemoteMediaPort<OwnedRemoteMediaPayload> {
  _Port({this.result, List<OfflineResult<OwnedRemoteMediaPayload>>? results}) : results = results ?? [];

  final OfflineResult<OwnedRemoteMediaPayload>? result;
  final List<OfflineResult<OwnedRemoteMediaPayload>> results;
  final List<RemoteMediaRequest> requests = [];
  final List<_Operation> operations = [];

  @override
  CancellableMediaRequest<OwnedRemoteMediaPayload> request(RemoteMediaRequest request) {
    requests.add(request);
    final operation = _Operation(results.isNotEmpty ? results.removeAt(0) : result);
    operations.add(operation);
    return operation;
  }

  @override
  Future<void> cancelAll() async {}
}

final class _Lease implements RemoteMediaPayloadLease {
  _Lease(this._bytes);

  final Uint8List _bytes;
  bool _released = false;

  @override
  Uint8List get bytes => _bytes;

  @override
  bool get isReleased => _released;

  @override
  void release() => _released = true;
}

final class _Operation implements CancellableMediaRequest<OwnedRemoteMediaPayload> {
  _Operation(OfflineResult<OwnedRemoteMediaPayload>? result) {
    if (result != null) {
      _result.complete(result);
    }
  }

  final Completer<OfflineResult<OwnedRemoteMediaPayload>> _result = Completer();
  int cancelCount = 0;

  @override
  Stream<MediaRequestProgress> get progress => const Stream.empty();

  @override
  Future<OfflineResult<OwnedRemoteMediaPayload>> get result => _result.future;

  @override
  Future<void> cancel() async {
    cancelCount++;
    if (!_result.isCompleted) {
      _result.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    }
  }
}

extension on RemoteImageProvider {
  Stream<ImageInfo> loadForTesting(ImageDecoderCallback decode) {
    final request = RemoteImageRequest(
      media: media,
      uri: url,
      policy: access.policy,
      kind: kind,
      expectedContextGeneration: access.policy == RemoteMediaPolicy.cacheThenNetwork
          ? access.expectedContextGeneration
          : null,
    );
    return loadRequest(request, decode, isFinal: true);
  }
}

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
