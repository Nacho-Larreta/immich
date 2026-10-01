import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/photo_manager_manual_source_adapter.dart';
import 'package:mocktail/mocktail.dart';

import '../../../fixtures/asset.stub.dart';
import '../../../infrastructure/repository.mock.dart';
import '../../../mocks/asset_entity.mock.dart';
import '../../../repository.mocks.dart';

void main() {
  late MockDriftLocalAssetRepository localAssets;
  late MockStorageRepository storage;
  late MockAssetMediaRepository media;
  late PhotoManagerManualSourceAdapter source;

  setUp(() {
    localAssets = MockDriftLocalAssetRepository();
    storage = MockStorageRepository();
    media = MockAssetMediaRepository();
    source = PhotoManagerManualSourceAdapter(localAssets, storage, media);
  });

  test('ordinary video source retains metadata and borrowed path for staging', () async {
    final video = LocalAssetStub.image1.copyWith(type: AssetType.video, durationMs: 25000);
    final entity = MockAssetEntity();
    when(() => localAssets.getById(video.id)).thenAnswer((_) async => video);
    when(() => storage.getAssetEntityForAsset(video)).thenAnswer((_) async => entity);
    when(() => entity.isLivePhoto).thenReturn(false);
    when(() => storage.isAssetAvailableLocally(video.id)).thenAnswer((_) async => true);
    when(() => storage.getFileForAsset(video.id)).thenAnswer((_) async => File('/borrowed/video.mov'));
    when(() => media.getOriginalFilename(video.id)).thenAnswer((_) async => 'video.mov');

    final result = await source.load(video.id);

    expect(result?.asset.duration, const Duration(seconds: 25));
    expect(result?.primaryBorrowedPath, '/borrowed/video.mov');
    expect(result?.primaryOriginalFileName, 'video.mov');
    expect(result?.isLivePhoto, isFalse);
    verifyNever(() => storage.clearCache());
  });

  test('iCloud Live Photo without motion export remains unavailable', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final image = LocalAssetStub.image1;
    final entity = MockAssetEntity();
    when(() => localAssets.getById(image.id)).thenAnswer((_) async => image);
    when(() => storage.getAssetEntityForAsset(image)).thenAnswer((_) async => entity);
    when(() => entity.isLivePhoto).thenReturn(true);
    when(() => storage.isAssetAvailableLocally(image.id)).thenAnswer((_) async => false);
    when(() => storage.loadFileFromCloud(image.id)).thenAnswer((_) async => File('/borrowed/cloud.heic'));
    when(() => storage.loadMotionFileFromCloud(image.id)).thenAnswer((_) async => null);

    expect(await source.load(image.id), isNull);
    verifyNever(() => storage.clearCache());
  });

  test('missing asset never constructs a source from stale metadata', () async {
    when(() => localAssets.getById('missing')).thenAnswer((_) async => null);

    expect(await source.load('missing'), isNull);
    verifyNever(() => storage.getFileForAsset(any()));
  });
}
