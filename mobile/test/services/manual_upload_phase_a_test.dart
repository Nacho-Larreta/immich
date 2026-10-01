import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_result.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../fixtures/asset.stub.dart';
import '../domain/service.mock.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';

class _Connectivity extends Mock implements ConnectivitySnapshotMonitorPort {}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    registerFallbackValue(File('/private/tmp/unused-upload-test-file'));
    registerFallbackValue(<String, String>{});
    final db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
    await Store.put(StoreKey.deviceId, 'test-device');
    addTearDown(db.close);
  });

  late MockUploadRepository uploads;
  late MockStorageRepository storage;
  late MockDriftBackupRepository backups;
  late MockAppSettingsService settings;
  late MockAssetMediaRepository media;
  late ForegroundUploadService service;

  setUp(() {
    uploads = MockUploadRepository();
    storage = MockStorageRepository();
    backups = MockDriftBackupRepository();
    settings = MockAppSettingsService();
    media = MockAssetMediaRepository();
    service = ForegroundUploadService(uploads, storage, backups, _Connectivity(), settings, media);
    when(() => settings.getSetting(AppSettingsEnum.useCellularForUploadPhotos)).thenReturn(false);
    when(() => settings.getSetting(AppSettingsEnum.useCellularForUploadVideos)).thenReturn(false);
    when(() => storage.clearCache()).thenAnswer((_) async {});
  });

  test('manual reader and unrelated sentinel survive automatic startup and cancellation', () async {
    final directory = await Directory.systemTemp.createTemp('manual-reader-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/borrowed.jpg')..writeAsStringSync('image-bytes');
    final sentinel = File('${directory.path}/other-consumer.mov')..writeAsStringSync('video-bytes');
    _source(storage, media, LocalAssetStub.image1, source);
    final readerStarted = Completer<void>();
    final settle = Completer<UploadResult>();
    when(
      () => uploads.uploadFile(
        file: source,
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'asset_upload',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    ).thenAnswer((_) async {
      final reader = await source.open();
      await reader.readByte();
      readerStarted.complete();
      try {
        return await settle.future;
      } finally {
        await reader.close();
      }
    });
    var purgeEnabled = false;
    when(() => storage.clearCache()).thenAnswer((_) async {
      if (!purgeEnabled) return;
      if (await source.exists()) await source.delete();
      if (await sentinel.exists()) await sentinel.delete();
    });
    final manual = service.uploadManual([LocalAssetStub.image1]);
    await readerStarted.future;
    purgeEnabled = true;

    when(() => backups.getCandidates('user-a')).thenAnswer((_) async => []);
    when(() => uploads.cancelAndDrain(any())).thenAnswer((_) async => true);
    final automatic = BackgroundUploadService(
      uploads,
      storage,
      MockDriftLocalAssetRepository(),
      backups,
      settings,
      media,
    );
    addTearDown(automatic.dispose);
    await automatic.uploadBackupCandidates(
      'user-a',
      binding: _binding(),
      lease: _lease(),
      isBindingCurrent: () => true,
    );
    expect(await automatic.cancel(), 0);

    expect(await source.exists(), isTrue);
    expect(await sentinel.exists(), isTrue);
    settle.complete(UploadResult.success(remoteAssetId: 'remote-image'));
    expect((await manual).succeededCount, 1);
    verifyNever(storage.clearCache);
  });

  test('one manual consumer finishing cannot remove another borrowed source', () async {
    final directory = await Directory.systemTemp.createTemp('manual-consumers-');
    addTearDown(() => directory.delete(recursive: true));
    final firstFile = File('${directory.path}/first.jpg')..writeAsStringSync('first');
    final secondFile = File('${directory.path}/second.jpg')..writeAsStringSync('second');
    _source(storage, media, LocalAssetStub.image1, firstFile);
    _source(storage, media, LocalAssetStub.image2, secondFile);
    final secondStarted = Completer<void>();
    final finishSecond = Completer<UploadResult>();
    when(
      () => uploads.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'asset_upload',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    ).thenAnswer((invocation) async {
      final file = invocation.namedArguments[#file] as File;
      if (file.path == firstFile.path) return UploadResult.success(remoteAssetId: 'remote-first');
      secondStarted.complete();
      return finishSecond.future;
    });

    final upload = service.uploadManual([LocalAssetStub.image1, LocalAssetStub.image2]);
    await secondStarted.future;
    await pumpEventQueue();
    expect(await firstFile.exists(), isTrue);
    expect(await secondFile.exists(), isTrue);
    finishSecond.complete(UploadResult.success(remoteAssetId: 'remote-second'));
    expect((await upload).succeededCount, 2);
    verifyNever(storage.clearCache);
  });

  test('manual result counts failed, cancelled, and pending assets without inventing success', () async {
    final directory = await Directory.systemTemp.createTemp('manual-outcomes-');
    addTearDown(() => directory.delete(recursive: true));
    final source = File('${directory.path}/image.jpg')..writeAsStringSync('image');
    _source(storage, media, LocalAssetStub.image1, source);
    when(
      () => uploads.uploadFile(
        file: source,
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'asset_upload',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    ).thenAnswer((_) async => UploadResult.error(errorMessage: 'offline'));
    final failures = <String>[];

    final failed = await service.uploadManual([
      LocalAssetStub.image1,
    ], callbacks: UploadCallbacks(onError: (id, _) => failures.add(id)));

    expect(failed.succeededCount, 0);
    expect(failed.failedCount, 1);
    expect(failed.outcomes.single.state, ManualAssetUploadState.failed);
    expect(failures, [LocalAssetStub.image1.id]);

    final cancelledToken = Completer<void>()..complete();
    final cancelled = await service.uploadManual([LocalAssetStub.image1], cancelToken: cancelledToken);
    expect(cancelled.cancelledCount, 1);
    expect(cancelled.succeededCount, 0);

    when(
      () => uploads.uploadFile(
        file: source,
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'asset_upload',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    ).thenAnswer((_) async => UploadResult.staleContext());
    final pending = await service.uploadManual([LocalAssetStub.image1]);
    expect(pending.pendingCount, 1);
    expect(pending.cancelledCount, 0);
  });

  test('Live Photo without a motion file does not upload a still image alone', () async {
    final directory = await Directory.systemTemp.createTemp('manual-live-missing-motion-');
    addTearDown(() => directory.delete(recursive: true));
    final still = File('${directory.path}/live.heic')..writeAsStringSync('still');
    _source(storage, media, LocalAssetStub.image1, still, isLivePhoto: true);

    final result = await service.uploadManual([LocalAssetStub.image1]);

    expect(result.failedCount, 1);
    verifyNever(
      () => uploads.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    );
  });

  test('iCloud Live Photo without motion export does not upload a still image alone', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = await Directory.systemTemp.createTemp('manual-icloud-missing-motion-');
    addTearDown(() => directory.delete(recursive: true));
    final still = File('${directory.path}/cloud-live.heic')..writeAsStringSync('still');
    _source(storage, media, LocalAssetStub.image1, still, isLivePhoto: true);
    when(() => storage.isAssetAvailableLocally(LocalAssetStub.image1.id)).thenAnswer((_) async => false);
    when(
      () => storage.loadFileFromCloud(LocalAssetStub.image1.id, progressHandler: any(named: 'progressHandler')),
    ).thenAnswer((_) async => still);
    when(
      () => storage.loadMotionFileFromCloud(LocalAssetStub.image1.id, progressHandler: any(named: 'progressHandler')),
    ).thenAnswer((_) async => null);

    final result = await service.uploadManual([LocalAssetStub.image1]);

    expect(result.failedCount, 1);
    expect(result.succeededCount, 0);
    verifyNever(
      () => uploads.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: any(named: 'logContext'),
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    );
  });

  test('manual image and video keep metadata and server duplicate IDs count as success', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
    addTearDown(() => debugDefaultTargetPlatformOverride = null);
    final directory = await Directory.systemTemp.createTemp('manual-metadata-');
    addTearDown(() => directory.delete(recursive: true));
    final imageFile = File('${directory.path}/photo.heic')..writeAsStringSync('still');
    final videoFile = File('${directory.path}/clip.mov')..writeAsStringSync('video');
    final image = LocalAsset(
      id: 'image-icloud',
      name: 'photo.heic',
      type: AssetType.image,
      createdAt: DateTime.utc(2025, 1, 1),
      updatedAt: DateTime.utc(2025, 1, 2),
      cloudId: 'icloud-image',
      isFavorite: true,
      adjustmentTime: DateTime.utc(2025, 1, 2),
      latitude: -34.6,
      longitude: -58.4,
      playbackStyle: AssetPlaybackStyle.image,
      isEdited: false,
    );
    final video = LocalAsset(
      id: 'video-1',
      name: 'clip.mov',
      type: AssetType.video,
      createdAt: DateTime.utc(2025, 3, 4),
      updatedAt: DateTime.utc(2025, 3, 5),
      durationMs: 25000,
      isFavorite: true,
      playbackStyle: AssetPlaybackStyle.video,
      isEdited: false,
    );
    _source(storage, media, image, imageFile);
    _source(storage, media, video, videoFile);
    final requests = <String, Map<String, String>>{};
    when(
      () => uploads.uploadFile(
        file: any(named: 'file'),
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'asset_upload',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    ).thenAnswer((invocation) async {
      final file = invocation.namedArguments[#file] as File;
      requests[file.path] = Map<String, String>.of(invocation.namedArguments[#fields] as Map<String, String>);
      return UploadResult.success(remoteAssetId: file.path == imageFile.path ? 'existing-image-id' : 'new-video-id');
    });

    final result = await service.uploadManual([image, video]);

    expect(result.succeededCount, 2);
    expect(result.outcomes.map((outcome) => outcome.remoteAssetId), ['existing-image-id', 'new-video-id']);
    expect(requests[imageFile.path], containsPair('deviceAssetId', image.id));
    expect(requests[imageFile.path], containsPair('isFavorite', 'true'));
    final metadata = jsonDecode(requests[imageFile.path]!['metadata']!) as List<dynamic>;
    expect(jsonEncode(metadata), contains('icloud-image'));
    expect(requests[videoFile.path], containsPair('deviceAssetId', video.id));
    expect(requests[videoFile.path], containsPair('duration', '0:00:25.000000'));
    expect(requests[videoFile.path], containsPair('fileCreatedAt', video.createdAt.toIso8601String()));
    expect(requests[videoFile.path], containsPair('fileModifiedAt', video.updatedAt.toIso8601String()));
    expect(requests[videoFile.path]!.containsKey('metadata'), isFalse);
  });

  test('Live Photo motion failure does not upload the still or report success', () async {
    final directory = await Directory.systemTemp.createTemp('manual-live-motion-');
    addTearDown(() => directory.delete(recursive: true));
    final still = File('${directory.path}/live.heic')..writeAsStringSync('still');
    final motion = File('${directory.path}/live.mov')..writeAsStringSync('motion');
    _source(storage, media, LocalAssetStub.image1, still, motion: motion);
    when(
      () => uploads.uploadFile(
        file: motion,
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'live_photo_video',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    ).thenAnswer((_) async => UploadResult.error(errorMessage: 'motion unavailable'));

    final result = await service.uploadManual([LocalAssetStub.image1]);

    expect(result.failedCount, 1);
    expect(result.succeededCount, 0);
    verifyNever(
      () => uploads.uploadFile(
        file: still,
        originalFileName: any(named: 'originalFileName'),
        fields: any(named: 'fields'),
        cancelToken: any(named: 'cancelToken'),
        onProgress: any(named: 'onProgress'),
        logContext: 'asset_upload',
        apiEndpoint: any(named: 'apiEndpoint'),
        isContextCurrent: any(named: 'isContextCurrent'),
      ),
    );
  });
}

void _source(
  MockStorageRepository storage,
  MockAssetMediaRepository media,
  LocalAsset asset,
  File file, {
  File? motion,
  bool isLivePhoto = false,
}) {
  final entity = MockAssetEntity();
  when(() => entity.isLivePhoto).thenReturn(isLivePhoto || motion != null);
  when(() => storage.getAssetEntityForAsset(asset)).thenAnswer((_) async => entity);
  when(() => storage.isAssetAvailableLocally(asset.id)).thenAnswer((_) async => true);
  when(() => storage.getFileForAsset(asset.id)).thenAnswer((_) async => file);
  if (isLivePhoto || motion != null) {
    when(() => storage.getMotionFileForAsset(asset)).thenAnswer((_) async => motion);
  }
  when(() => media.getOriginalFilename(asset.id)).thenAnswer((_) async => asset.name);
}

BackupRunBinding _binding() => BackupRunBinding(
  userId: 'user-a',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: 3,
  apiEndpoint: Uri.parse('https://photos.example/api'),
  canonicalOrigin: Uri.parse('https://photos.example'),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportEpoch: 1,
  transportRevision: 4,
  localLeaseRevision: 5,
);

BackupExecutionLease _lease() => BackupExecutionLease(
  mode: BackupExecutionMode.background,
  runToken: 'manual-overlap',
  bindingDigest: _binding().digest,
  expiresAt: DateTime.now().add(const Duration(minutes: 2)),
  activityRevision: 0,
  callbacksInFlight: 0,
);
