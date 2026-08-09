import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';

void main() {
  test('defines approved remote and local media policies', () {
    expect(RemoteMediaPolicy.values, [RemoteMediaPolicy.cacheOnly, RemoteMediaPolicy.cacheThenNetwork]);
    expect(LocalMediaPolicy.values, [LocalMediaPolicy.localOnly, LocalMediaPolicy.allowICloud]);
    expect(MediaRequestKind.values, [MediaRequestKind.thumbnail, MediaRequestKind.original]);
  });

  test('remote request preserves exact resource origin and policy', () {
    final resource = Uri.parse('https://photos.example.test/api/assets/asset-1/thumbnail');
    final request = RemoteMediaRequest(
      requestId: 11,
      resource: resource,
      policy: RemoteMediaPolicy.cacheOnly,
      kind: MediaRequestKind.thumbnail,
    );

    expect(request.resource, resource);
    expect(request.origin, Uri.parse('https://photos.example.test'));
    expect(request.policy, RemoteMediaPolicy.cacheOnly);
  });

  test('local request rejects an empty asset identity', () {
    expect(
      () => LocalMediaRequest(
        requestId: 1,
        assetId: '',
        assetType: AssetType.image,
        policy: LocalMediaPolicy.localOnly,
        rendition: LocalMediaRendition.thumbnail(widthPx: 100, heightPx: 100),
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('local request preserves an explicit valid thumbnail rendition', () {
    final request = LocalMediaRequest(
      requestId: 7,
      assetId: 'asset-1',
      assetType: AssetType.video,
      policy: LocalMediaPolicy.localOnly,
      rendition: LocalMediaRendition.thumbnail(widthPx: 320, heightPx: 180),
    );

    expect(request.assetType, AssetType.video);
    expect(request.policy, LocalMediaPolicy.localOnly);
    expect(request.rendition, isA<LocalMediaThumbnailRendition>());
  });

  test('local thumbnail rendition rejects zero dimensions without a sentinel', () {
    expect(() => LocalMediaRendition.thumbnail(widthPx: 0, heightPx: 100), throwsArgumentError);
    expect(() => LocalMediaRendition.thumbnail(widthPx: 100, heightPx: 0), throwsArgumentError);
  });

  test('local request only accepts image or video assets', () {
    expect(
      () => LocalMediaRequest(
        requestId: 1,
        assetId: 'asset-1',
        assetType: AssetType.audio,
        policy: LocalMediaPolicy.allowICloud,
        rendition: const LocalMediaRendition.originalEncoded(),
      ),
      throwsArgumentError,
    );
  });

  test('media progress stays between zero and one', () {
    expect(MediaRequestProgress(requestId: 1, fraction: 0.5).fraction, 0.5);
    expect(() => MediaRequestProgress(requestId: 1, fraction: 1.1), throwsA(isA<ArgumentError>()));
    expect(() => MediaRequestProgress(requestId: -1, fraction: 0.5), throwsA(isA<ArgumentError>()));
    expect(() => MediaRequestProgress(requestId: 1, fraction: double.nan), throwsA(isA<ArgumentError>()));
  });

  test('remote request rejects non-HTTP resources', () {
    expect(
      () => RemoteMediaRequest(
        requestId: 1,
        resource: Uri.parse('file:///tmp/image.jpg'),
        policy: RemoteMediaPolicy.cacheOnly,
        kind: MediaRequestKind.thumbnail,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
