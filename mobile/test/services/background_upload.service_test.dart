import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_reconciliation_quarantine.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/backup_callback_fence.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/background_downloader_task_registry_adapter.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../domain/service.mock.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../mocks/asset_entity.mock.dart';
import '../repository.mocks.dart';

const _candidateKey = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa';
const _otherCandidateKey = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb';

void main() {
  late BackgroundUploadService sut;
  late MockUploadRepository mockUploadRepository;
  late MockStorageRepository mockStorageRepository;
  late MockDriftLocalAssetRepository mockLocalAssetRepository;
  late MockDriftBackupRepository mockBackupRepository;
  late MockAppSettingsService mockAppSettingsService;
  late MockAssetMediaRepository mockAssetMediaRepository;
  late Drift db;

  test('attached relaunch validates original binding against native evidence without process-local epochs', () {
    final binding = _binding();
    final authority = UploadBindingAuthority.fromBinding(binding);
    final metadata = UploadTaskMetadata(
      localAssetId: 'opaque-local',
      isLivePhotos: false,
      livePhotoVideoId: '',
      ownership: BackupTaskMetadata.current(
        runToken: 'run-token',
        bindingDigest: binding.digest,
        phase: BackupTaskPhase.primary,
      ),
      expectedNativeRevision: binding.nativeGeneration,
      bindingAuthority: authority,
      candidateKey: _candidateKey,
    );
    final task = UploadTask(
      taskId: 'opaque-task',
      url: '${binding.apiEndpoint}/assets',
      filename: 'asset.jpg',
      group: kBackupGroup,
      metaData: metadata.toJson(),
    );
    final evidence = NativeServerAccessEvidence(
      apiEndpoint: binding.apiEndpoint,
      canonicalOrigin: binding.canonicalOrigin,
      schemePolicy: binding.schemePolicy,
      sessionEpoch: binding.sessionEpoch,
      generation: binding.nativeGeneration,
      confirmed: true,
      fenced: false,
    );
    final relaunchedIdentity = ReachabilityIdentity(sessionEpoch: 0, probeGeneration: 0);

    expect(
      validateOwnedTaskBinding(
        metadata: metadata,
        task: task,
        evidence: evidence,
        evidenceAfter: evidence,
        identity: relaunchedIdentity,
        identityAfter: relaunchedIdentity,
        userId: binding.userId,
        userIdAfter: binding.userId,
        attachedWorker: true,
      ),
      binding,
    );
    expect(
      validateOwnedTaskBinding(
        metadata: metadata,
        task: task,
        evidence: evidence,
        evidenceAfter: NativeServerAccessEvidence(
          apiEndpoint: binding.apiEndpoint,
          canonicalOrigin: Uri.parse('https://stale.example'),
          schemePolicy: binding.schemePolicy,
          sessionEpoch: binding.sessionEpoch,
          generation: binding.nativeGeneration + 1,
          confirmed: true,
          fenced: false,
        ),
        identity: relaunchedIdentity,
        identityAfter: relaunchedIdentity,
        userId: binding.userId,
        userIdAfter: binding.userId,
        attachedWorker: true,
      ),
      isNull,
    );
  });

  setUpAll(() async {
    registerFallbackValue(AppSettingsEnum.useCellularForUploadPhotos);

    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/path_provider'),
      (MethodCall methodCall) async => 'test',
    );
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));

    await Store.put(StoreKey.serverEndpoint, 'http://test-server.com');
    await Store.put(StoreKey.deviceId, 'test-device-id');
  });

  setUp(() {
    mockUploadRepository = MockUploadRepository();
    mockStorageRepository = MockStorageRepository();
    mockLocalAssetRepository = MockDriftLocalAssetRepository();
    mockBackupRepository = MockDriftBackupRepository();
    mockAppSettingsService = MockAppSettingsService();
    mockAssetMediaRepository = MockAssetMediaRepository();

    when(() => mockAppSettingsService.getSetting(AppSettingsEnum.useCellularForUploadVideos)).thenReturn(false);
    when(() => mockAppSettingsService.getSetting(AppSettingsEnum.useCellularForUploadPhotos)).thenReturn(false);
    when(() => mockUploadRepository.replayUndeliveredUpdates()).thenAnswer((_) async {});

    sut = BackgroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockLocalAssetRepository,
      mockBackupRepository,
      mockAppSettingsService,
      mockAssetMediaRepository,
    );

    mockUploadRepository.onUploadStatus = (_) {};
    mockUploadRepository.onTaskProgress = (_) {};
  });

  tearDown(() {
    sut.dispose();
  });

  test('owned backup rejects failed connectivity gate before storage and candidate query', () async {
    final binding = _binding();
    final service = BackgroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockLocalAssetRepository,
      mockBackupRepository,
      mockAppSettingsService,
      mockAssetMediaRepository,
      canContinueOwnedUpload: (_) async => false,
    );
    addTearDown(service.dispose);

    await service.uploadBackupCandidates(
      binding.userId,
      binding: binding,
      lease: BackupExecutionLease(
        mode: BackupExecutionMode.background,
        runToken: 'run-token',
        bindingDigest: binding.digest,
        expiresAt: DateTime.utc(2026, 8, 11, 12),
        activityRevision: 0,
        callbacksInFlight: 0,
      ),
      isBindingCurrent: () => true,
    );

    verifyNever(() => mockStorageRepository.clearCache());
    verifyNever(() => mockBackupRepository.getCandidates(any()));
    verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
  });

  group('getUploadTask', () {
    test('should call getOriginalFilename from AssetMediaRepository for regular photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => 'OriginalPhoto.jpg');

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.fields['filename'], equals('OriginalPhoto.jpg'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should call getOriginalFilename when original filename is null', () async {
      final asset = LocalAssetStub.image2;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => null);

      final task = await sut.getUploadTask(asset);

      expect(task, isNotNull);
      expect(task!.fields['filename'], equals(asset.name));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should call getOriginalFilename for live photo', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/file.mov');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getMotionFileForAsset(asset)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(asset.id),
      ).thenAnswer((_) async => 'OriginalLivePhoto.HEIC');

      final task = await sut.getUploadTask(asset);
      expect(task, isNotNull);
      // For live photos, extension should be changed to match the video file
      expect(task!.fields['filename'], equals('OriginalLivePhoto.mov'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });
  });

  group('getLivePhotoUploadTask', () {
    test('should call getOriginalFilename for live photo upload task', () async {
      final asset = LocalAssetStub.image1;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/livephoto.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(asset.id),
      ).thenAnswer((_) async => 'OriginalLivePhoto.HEIC');

      final task = await sut.getLivePhotoUploadTask(asset, 'video-id-123');

      expect(task, isNotNull);
      expect(task!.fields['filename'], equals('OriginalLivePhoto.HEIC'));
      expect(task.fields['livePhotoVideoId'], equals('video-id-123'));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });

    test('should call getOriginalFilename when original filename is null', () async {
      final asset = LocalAssetStub.image2;
      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/fallback.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(asset)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(asset.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).thenAnswer((_) async => null);

      final task = await sut.getLivePhotoUploadTask(asset, 'video-id-456');
      expect(task, isNotNull);
      // Should fall back to asset.name when original filename is null
      expect(task!.fields['filename'], equals(asset.name));
      verify(() => mockAssetMediaRepository.getOriginalFilename(asset.id)).called(1);
    });
  });

  group('Server Info - cloudId and eTag metadata', () {
    test('should include cloudId and eTag metadata on iOS when server version is 2.4+', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutWithV24 = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
      );
      addTearDown(() => sutWithV24.dispose());

      final assetWithCloudId = LocalAsset(
        id: 'test-asset-id',
        name: 'test.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: 'cloud-id-123',
        latitude: 37.7749,
        longitude: -122.4194,
        adjustmentTime: DateTime(2026, 1, 2),
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithCloudId.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(assetWithCloudId.id)).thenAnswer((_) async => 'test.jpg');

      final task = await sutWithV24.getUploadTask(assetWithCloudId);

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isTrue);

      final metadata = jsonDecode(task.fields['metadata']!) as List;
      expect(metadata, hasLength(1));
      expect(metadata[0]['key'], equals('mobile-app'));
      expect(metadata[0]['value']['iCloudId'], equals('cloud-id-123'));
      expect(metadata[0]['value']['createdAt'], isNotNull);
      expect(metadata[0]['value']['adjustmentTime'], isNotNull);
      expect(metadata[0]['value']['latitude'], isNotNull);
      expect(metadata[0]['value']['longitude'], isNotNull);
    });

    test('should NOT include metadata on Android regardless of server version', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutAndroid = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
      );
      addTearDown(() => sutAndroid.dispose());

      final assetWithCloudId = LocalAsset(
        id: 'test-asset-id',
        name: 'test.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: 'cloud-id-123',
        latitude: 37.7749,
        longitude: -122.4194,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithCloudId.id)).thenAnswer((_) async => mockFile);
      when(() => mockAssetMediaRepository.getOriginalFilename(assetWithCloudId.id)).thenAnswer((_) async => 'test.jpg');

      final task = await sutAndroid.getUploadTask(assetWithCloudId);

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isFalse);
    });

    test('should NOT include metadata when cloudId is null even on iOS with server 2.4+', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutWithV24 = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
      );
      addTearDown(() => sutWithV24.dispose());

      final assetWithoutCloudId = LocalAsset(
        id: 'test-asset-id',
        name: 'test.jpg',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: null, // No cloudId
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/test.jpg');

      when(() => mockEntity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithoutCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithoutCloudId.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(assetWithoutCloudId.id),
      ).thenAnswer((_) async => 'test.jpg');

      final task = await sutWithV24.getUploadTask(assetWithoutCloudId);

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isFalse);
    });

    test('should include metadata for live photos with cloudId on iOS 2.4+', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      addTearDown(() => debugDefaultTargetPlatformOverride = null);

      final sutWithV24 = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
      );
      addTearDown(() => sutWithV24.dispose());

      final assetWithCloudId = LocalAsset(
        id: 'test-livephoto-id',
        name: 'livephoto.heic',
        type: AssetType.image,
        createdAt: DateTime(2025, 1, 1),
        updatedAt: DateTime(2025, 1, 2),
        cloudId: 'cloud-id-livephoto',
        latitude: 37.7749,
        longitude: -122.4194,
        playbackStyle: AssetPlaybackStyle.image,
        isEdited: false,
      );

      final mockEntity = MockAssetEntity();
      final mockFile = File('/path/to/livephoto.heic');

      when(() => mockEntity.isLivePhoto).thenReturn(true);
      when(() => mockStorageRepository.getAssetEntityForAsset(assetWithCloudId)).thenAnswer((_) async => mockEntity);
      when(() => mockStorageRepository.getFileForAsset(assetWithCloudId.id)).thenAnswer((_) async => mockFile);
      when(
        () => mockAssetMediaRepository.getOriginalFilename(assetWithCloudId.id),
      ).thenAnswer((_) async => 'livephoto.heic');

      final task = await sutWithV24.getLivePhotoUploadTask(assetWithCloudId, 'video-123');

      expect(task, isNotNull);
      expect(task!.fields.containsKey('metadata'), isTrue);
      expect(task.fields['livePhotoVideoId'], equals('video-123'));

      final metadata = jsonDecode(task.fields['metadata']!) as List;
      expect(metadata, hasLength(1));
      expect(metadata[0]['key'], equals('mobile-app'));
      expect(metadata[0]['value']['iCloudId'], equals('cloud-id-livephoto'));
    });
  });

  group('durable backup ownership', () {
    BackgroundUploadService ownedServiceFor(BackupExecutionLeasePort leases) => BackgroundUploadService(
      mockUploadRepository,
      mockStorageRepository,
      mockLocalAssetRepository,
      mockBackupRepository,
      mockAppSettingsService,
      mockAssetMediaRepository,
      leasePort: leases,
      validateBinding: (_, _) => _binding(),
      reconcileOwnedSuccess: (_) async => true,
    );

    test('background snapshot preserves only the admitted owner waiting and paused states', () async {
      const waitingClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'waiting');
      const pausedClaim = BackupTaskClaim(group: BackupTaskGroup.livePhoto, taskId: 'paused');
      final lease = _leaseWithClaims({waitingClaim, pausedClaim});
      final leases = _ExactOwnerLeasePort(lease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer(
        (_) async => [
          BackupTaskSnapshot(
            taskId: 'waiting',
            group: BackupTaskGroup.primary,
            status: BackupTaskStatus.waitingToRetry,
            metadata: _taskOwnership(),
          ),
          BackupTaskSnapshot(
            taskId: 'paused',
            group: BackupTaskGroup.livePhoto,
            status: BackupTaskStatus.paused,
            metadata: _taskOwnership(),
          ),
          const BackupTaskSnapshot(
            taskId: 'foreign',
            group: BackupTaskGroup.primary,
            status: BackupTaskStatus.running,
            metadata: BackupTaskMetadata.current(
              runToken: 'other-run',
              bindingDigest: 'other-binding',
              phase: BackupTaskPhase.primary,
            ),
          ),
        ],
      );

      final snapshot = await ownedService.readSnapshot(EagerBackgroundUploadOwner.fromLease(lease));

      expect(snapshot.activeCount, 2);
      expect(snapshot.waitingToRetryCount, 1);
      expect(snapshot.pausedCount, 1);
    });

    test('owner change while reading the native snapshot fails closed', () async {
      const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'running');
      final lease = _leaseWithClaims({claim});
      final otherLease = BackupExecutionLease(
        mode: BackupExecutionMode.background,
        runToken: 'other-run',
        bindingDigest: 'other-binding',
        expiresAt: lease.expiresAt,
        activityRevision: lease.activityRevision,
        callbacksInFlight: 0,
        outstandingClaims: {claim},
      );
      final leases = _LeasePort(readSequence: [lease, otherLease]);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer(
        (_) async => [
          BackupTaskSnapshot(
            taskId: claim.taskId,
            group: claim.group,
            status: BackupTaskStatus.running,
            metadata: _taskOwnership(),
          ),
        ],
      );

      final snapshot = await ownedService.readSnapshot(EagerBackgroundUploadOwner.fromLease(lease));

      expect(snapshot.ownerState, EagerBackgroundOwnerState.authorityChanged);
    });

    test('waiting owner is observed without invoking the global downloader start', () async {
      const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'waiting');
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer(
        (_) async => [
          BackupTaskSnapshot(
            taskId: claim.taskId,
            group: claim.group,
            status: BackupTaskStatus.waitingToRetry,
            metadata: _taskOwnership(),
          ),
        ],
      );

      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(lease));

      expect(disposition, EagerBackgroundResumeDisposition.recoveryPending);
    });

    test('resumeOwned replays an exact terminal mailbox update before its final owner snapshot', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      late final BackgroundUploadService ownedService;
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer(
        (_) async => [
          BackupTaskSnapshot(
            taskId: claim.taskId,
            group: claim.group,
            status: BackupTaskStatus.running,
            metadata: _taskOwnership(),
          ),
        ],
      );
      when(() => mockUploadRepository.replayUndeliveredUpdates()).thenAnswer((_) async {
        ownedService.handleDownloaderStatusForTest(update);
      });
      ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final eventFuture = ownedService
          .eventsFor(EagerBackgroundUploadOwner.fromLease(lease))
          .firstWhere((event) => event.terminal != null);

      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(lease));

      expect(disposition, EagerBackgroundResumeDisposition.completed);
      final event = await eventFuture.timeout(const Duration(milliseconds: 50));
      expect(event.terminal, EagerBackgroundUploadTerminal.succeeded);
      expect(event.remainingActiveCount, 0);
      expect(leases.terminalClaims, {claim});
      verify(() => mockUploadRepository.replayUndeliveredUpdates()).called(1);
    });

    test('owner snapshot resolves a terminal mailbox update even when no event listener existed', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      late final BackgroundUploadService ownedService;
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => const []);
      when(() => mockUploadRepository.replayUndeliveredUpdates()).thenAnswer((_) async {
        ownedService.handleDownloaderStatusForTest(update);
      });
      ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);

      final snapshot = await ownedService.readSnapshot(EagerBackgroundUploadOwner.fromLease(lease));

      expect(snapshot.ownerState, EagerBackgroundOwnerState.completed);
      expect(snapshot.activeCount, 0);
      expect(leases.terminalClaims, {claim});
    });

    test('full iPhone reboot replays the durable terminal once and admits the next backup run', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({
        claim,
      }).copyWith(callbacksInFlight: 1, callbackClaims: {claim}, callbackIncarnations: {claim: 'process-a'});
      final leases = _ExactOwnerLeasePort(lease);
      late final UploadRepository rebootRepository;
      final gateway = _RebootTaskRegistryGateway(
        staleTrackingRecord: TaskRecord(update.task, TaskStatus.running, 0, 1),
        replayTerminal: () => rebootRepository.onUploadStatus?.call(update),
      );
      rebootRepository = UploadRepository(taskRegistry: gateway);
      final freshFence = BackupCallbackFence();
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: rebootRepository, callbackFence: freshFence);
      final ownedService = BackgroundUploadService(
        rebootRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
        callbackFence: freshFence,
        operationIncarnation: 'process-after-reboot',
        validateBinding: (_, _) => _binding(),
        reconcileOwnedSuccess: (_) async => true,
      );
      addTearDown(ownedService.dispose);
      final admission = await arbiter.acquireForeground(bindingDigest: lease.bindingDigest);
      expect(admission.disposition, BackupAdmissionDisposition.adoptedBackground);
      expect(admission.lease, lease);
      final events = <EagerBackgroundUploadEvent>[];
      final owner = EagerBackgroundUploadOwner.fromLease(admission.lease!);
      final subscription = ownedService.eventsFor(owner).listen(events.add);
      addTearDown(subscription.cancel);

      final disposition = await ownedService.resumeOwned(owner);

      expect(disposition, EagerBackgroundResumeDisposition.completed);
      expect(leases.orphanCallbackReleaseCalls, 1);
      expect(leases.terminalClaims, {claim});
      expect(events.where((event) => event.terminal != null).single.remainingActiveCount, 0);
      expect(gateway.replayCalls, 1);
      expect(gateway.nativeSnapshotReads, greaterThanOrEqualTo(2));
      expect(gateway.staleTrackingReads, greaterThanOrEqualTo(2));

      final nextAdmission = await arbiter.acquireForeground(bindingDigest: lease.bindingDigest);

      expect(nextAdmission.disposition, BackupAdmissionDisposition.acquired);
      expect(leases.terminalClaims, {claim});
      expect(gateway.replayCalls, 1);
    });

    test('mailbox replay processes the exact owner and leaves an interleaved foreign owner fail-closed', () async {
      final exact = _completeOwnedUpdate();
      final foreign = _completeOwnedUpdateFor(
        runToken: 'foreign-run',
        bindingDigest: 'foreign-binding',
        taskId: 'foreign-terminal',
        localAssetId: 'foreign-local',
      );
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: exact.task.taskId);
      final foreignClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: foreign.task.taskId);
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      late final BackgroundUploadService ownedService;
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => const []);
      when(() => mockUploadRepository.replayUndeliveredUpdates()).thenAnswer((_) async {
        ownedService.handleDownloaderStatusForTest(foreign);
        ownedService.handleDownloaderStatusForTest(exact);
      });
      ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final events = <EagerBackgroundUploadEvent>[];
      final subscription = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).listen(events.add);
      addTearDown(subscription.cancel);

      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(lease));
      await pumpEventQueue();

      expect(disposition, EagerBackgroundResumeDisposition.completed);
      expect(leases.terminalClaims, {claim});
      expect(leases.terminalClaims, isNot(contains(foreignClaim)));
      expect(events.where((event) => event.terminal != null), hasLength(1));
      expect(events.single.activity.localAssetId, 'opaque-local');
    });

    test('terminal replay cannot reclaim a callback claimed by the same process incarnation', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({
        claim,
      }).copyWith(callbacksInFlight: 1, callbackClaims: {claim}, callbackIncarnations: {claim: 'process-a'});
      final leases = _ExactOwnerLeasePort(lease);
      final fence = BackupCallbackFence();
      late final BackgroundUploadService ownedService;
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => const []);
      when(() => mockUploadRepository.replayUndeliveredUpdates()).thenAnswer((_) async {
        ownedService.handleDownloaderStatusForTest(update);
      });
      ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        callbackFence: fence,
        operationIncarnation: 'process-a',
        validateBinding: (_, _) => _binding(),
      );
      addTearDown(ownedService.dispose);

      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(lease));

      expect(disposition, EagerBackgroundResumeDisposition.recoveryPending);
      expect(leases.orphanCallbackReleaseCalls, 0);
      expect(leases.existing?.callbackClaims, {claim});
      expect(leases.terminalClaims, isEmpty);
    });

    test('relaunch quarantines and releases an exact enqueue claim absent from mailbox and two snapshots', () async {
      const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'orphaned-enqueue');
      final lease = _lease().copyWith(
        callbacksInFlight: 0,
        enqueueClaims: {claim},
        candidateKeys: {claim: _candidateKey},
        enqueueIncarnations: {claim: 'process-a'},
      );
      final leases = _ExactOwnerLeasePort(lease);
      final fence = BackupCallbackFence();
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry(), callbackFence: fence);
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => const []);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
        callbackFence: fence,
        operationIncarnation: 'process-b',
        validateBinding: (_, _) => _binding(),
      );
      addTearDown(ownedService.dispose);

      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(lease));

      expect(disposition, EagerBackgroundResumeDisposition.completed);
      expect(leases.events, containsAllInOrder(['markReconciliationPending', 'quarantine:completedTaskMissing']));
      expect(leases.released, isTrue);
      verify(() => mockUploadRepository.replayUndeliveredUpdates()).called(1);
      verify(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).called(greaterThanOrEqualTo(2));
    });

    test('legacy enqueue claim without terminal proof remains fail-closed', () async {
      const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'legacy-enqueue');
      final lease = _lease().copyWith(
        callbacksInFlight: 0,
        enqueueClaims: {claim},
        candidateKeys: {claim: _candidateKey},
      );
      final leases = _ExactOwnerLeasePort(lease);
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => const []);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        callbackFence: BackupCallbackFence(),
        operationIncarnation: 'process-b',
      );
      addTearDown(ownedService.dispose);

      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(lease));

      expect(disposition, EagerBackgroundResumeDisposition.recoveryPending);
      expect(leases.events.where((event) => event.startsWith('quarantine:')), isEmpty);
      expect(leases.existing, lease);
    });

    test('orphan recovery cannot quarantine an enqueue still live in the current process', () async {
      const ownership = BackupTaskMetadata.current(
        runToken: 'run-token',
        bindingDigest: 'binding-digest',
        phase: BackupTaskPhase.primary,
      );
      final claim = const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'live-enqueue');
      final lease = _lease().copyWith(callbacksInFlight: 0);
      final leases = _ExactOwnerLeasePort(lease);
      final fence = BackupCallbackFence();
      final plugin = Completer<List<bool>>();
      when(() => mockUploadRepository.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => const []);
      when(() => mockUploadRepository.enqueueBackgroundAll(any())).thenAnswer((_) => plugin.future);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        callbackFence: fence,
        operationIncarnation: 'process-a',
      );
      addTearDown(ownedService.dispose);
      final task = UploadTask(
        taskId: claim.taskId,
        url: 'https://photos.example/api/assets',
        filename: 'video.mov',
        group: kBackupGroup,
        metaData: UploadTaskMetadata(
          localAssetId: 'local-video',
          isLivePhotos: false,
          livePhotoVideoId: '',
          ownership: ownership,
          expectedNativeRevision: 3,
          bindingAuthority: UploadBindingAuthority.fromBinding(_binding()),
          candidateKey: _candidateKey,
        ).toJson(),
      );

      final enqueue = ownedService.enqueueTasks([task], ownership: ownership);
      await pumpEventQueue();
      final admitted = leases.existing!;
      expect(admitted.enqueueClaims, {claim});
      final disposition = await ownedService.resumeOwned(EagerBackgroundUploadOwner.fromLease(admitted));

      expect(disposition, EagerBackgroundResumeDisposition.recoveryPending);
      expect(leases.events.where((event) => event.startsWith('quarantine:')), isEmpty);
      expect(leases.existing?.enqueueClaims, {claim});
      plugin.complete([true]);
      expect(await enqueue, [true]);
      expect(leases.existing?.outstandingClaims, {claim});
    });

    test('owned progress is forwarded only to its exact eager owner stream', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final eventFuture = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).first;

      await ownedService.handleOwnedProgressForTest(TaskProgressUpdate(update.task, 0.4));
      final event = await eventFuture;

      expect(event.activity.kind, BackupUploadActivityKind.progress);
      expect(event.activity.localAssetId, 'opaque-local');
      expect(event.activity.progress, 0.4);
      expect(event.terminal, isNull);
    });

    test('owned nonterminal status is forwarded as owner activity', () async {
      final complete = _completeOwnedUpdate();
      final update = TaskStatusUpdate(complete.task, TaskStatus.running);
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final eventFuture = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).first;

      await ownedService.handleOwnedStatusForTest(update);

      final event = await eventFuture.timeout(const Duration(milliseconds: 20));
      expect(event.activity.kind, BackupUploadActivityKind.status);
      expect(event.terminal, isNull);
    });

    test('running and complete callbacks for one owner claim are processed FIFO', () async {
      final complete = _completeOwnedUpdate();
      final running = TaskStatusUpdate(complete.task, TaskStatus.running);
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: complete.task.taskId);
      final lease = _leaseWithClaims({claim});
      final releaseRunning = Completer<void>();
      final leases = _ExactOwnerLeasePort(lease, beforeFirstEnd: releaseRunning.future);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final events = <EagerBackgroundUploadEvent>[];
      final subscription = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).listen(events.add);
      addTearDown(subscription.cancel);

      final runningOperation = ownedService.handleOwnedStatusForTest(running);
      await pumpEventQueue();
      final completeOperation = ownedService.handleOwnedStatusForTest(complete);
      await pumpEventQueue();

      expect(leases.terminalClaims, isEmpty);
      expect(leases.events.where((event) => event == 'begin'), hasLength(1));

      releaseRunning.complete();
      await Future.wait([runningOperation, completeOperation]);

      expect(leases.events.where((event) => event == 'begin'), hasLength(2));
      expect(leases.terminalClaims, {claim});
      expect(events.where((event) => event.terminal != null), hasLength(1));
      expect(events.last.terminal, EagerBackgroundUploadTerminal.succeeded);
    });

    test('progress without the exact admitted claim emits nothing', () async {
      const otherClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'other-task');
      final lease = _leaseWithClaims({otherClaim});
      final leases = _ExactOwnerLeasePort(lease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final received = <EagerBackgroundUploadEvent>[];
      final subscription = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).listen(received.add);
      addTearDown(subscription.cancel);

      await ownedService.handleOwnedProgressForTest(TaskProgressUpdate(_completeOwnedUpdate().task, 0.4));
      await pumpEventQueue();

      expect(received, isEmpty);
    });

    test('interleaved owner progress never crosses the admitted owner stream', () async {
      final matching = _ownedProgressUpdate(
        runToken: 'run-token',
        bindingDigest: 'binding-digest',
        taskId: 'matching-task',
        localAssetId: 'matching-local',
      );
      final foreign = _ownedProgressUpdate(
        runToken: 'other-run',
        bindingDigest: 'other-binding',
        taskId: 'foreign-task',
        localAssetId: 'foreign-local',
      );
      const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'matching-task');
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final received = <EagerBackgroundUploadEvent>[];
      final subscription = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).listen(received.add);
      addTearDown(subscription.cancel);

      await ownedService.handleOwnedProgressForTest(foreign);
      await ownedService.handleOwnedProgressForTest(matching);

      expect(received.map((event) => event.activity.localAssetId), ['matching-local']);
    });

    test('owned success publishes a terminal eager event after durable claim consumption', () async {
      final update = _completeOwnedUpdate();
      final completedClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      const remainingClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'still-running');
      const lateClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'admitted-later');
      final admittedLease = _leaseWithClaims({completedClaim, remainingClaim});
      final currentLease = _leaseWithClaims({completedClaim, remainingClaim, lateClaim});
      final leases = _ExactOwnerLeasePort(currentLease);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final eventFuture = ownedService
          .eventsFor(EagerBackgroundUploadOwner.fromLease(admittedLease))
          .firstWhere((event) => event.terminal != null);

      await ownedService.handleOwnedStatusForTest(update);
      final event = await eventFuture;

      expect(event.activity.kind, BackupUploadActivityKind.success);
      expect(event.terminal, EagerBackgroundUploadTerminal.succeeded);
      expect(event.remainingActiveCount, 1);
      expect(leases.events, contains('consumeTerminal'));
    });

    test('terminal claim consumption CAS miss emits no eager terminal event', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final lease = _leaseWithClaims({claim});
      final leases = _ExactOwnerLeasePort(lease, consumeTerminalClaims: false);
      final ownedService = ownedServiceFor(leases);
      addTearDown(ownedService.dispose);
      final received = <EagerBackgroundUploadEvent>[];
      final subscription = ownedService.eventsFor(EagerBackgroundUploadOwner.fromLease(lease)).listen(received.add);
      addTearDown(subscription.cancel);

      await ownedService.handleOwnedStatusForTest(update);
      await pumpEventQueue();

      expect(received, isEmpty);
      expect(leases.existing?.outstandingClaims, {claim});
      expect(leases.events, contains('consumeTerminal'));
    });

    test('stale callback is dropped before repository work', () async {
      final leases = _LeasePort(claimCallbacks: false);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
      );
      addTearDown(ownedService.dispose);

      await ownedService.handleOwnedStatusForTest(_completeLivePhotoUpdate());

      verifyNever(() => mockLocalAssetRepository.getById(any()));
      expect(leases.events, ['begin']);
    });

    test('owned callback holds the shared recovery fence before its first repository await', () async {
      final begin = Completer<BackupExecutionLease?>();
      final leases = _LeasePort(begin: begin.future);
      final callbackFence = BackupCallbackFence();
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        callbackFence: callbackFence,
      );
      addTearDown(ownedService.dispose);

      final callback = ownedService.handleOwnedStatusForTest(_completeOwnedUpdate());
      await pumpEventQueue();

      expect(
        await callbackFence.fenceAndDrain(
          runToken: 'run-token',
          bindingDigest: 'binding-digest',
          timeout: const Duration(milliseconds: 1),
        ),
        isFalse,
      );
      begin.complete(null);
      await callback;
      expect(
        await callbackFence.fenceAndDrain(
          runToken: 'run-token',
          bindingDigest: 'binding-digest',
          timeout: const Duration(milliseconds: 1),
        ),
        isTrue,
      );
    });

    test('owned enqueue without native revision is rejected before durable or plugin side effects', () async {
      const ownership = BackupTaskMetadata.current(
        runToken: 'run-token',
        bindingDigest: 'binding-digest',
        phase: BackupTaskPhase.primary,
      );
      final leases = _LeasePort();
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
      );
      addTearDown(ownedService.dispose);
      final task = UploadTask(
        taskId: 'opaque',
        url: 'https://photos.example/api/assets',
        filename: 'asset.jpg',
        group: kBackupGroup,
        metaData: const UploadTaskMetadata(
          localAssetId: 'local',
          isLivePhotos: false,
          livePhotoVideoId: '',
          ownership: ownership,
          candidateKey: _candidateKey,
        ).toJson(),
      );

      expect(await ownedService.enqueueTasks([task], ownership: ownership), [false]);
      expect(leases.events, isEmpty);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('owned enqueue skips quarantined candidate and admits another candidate', () async {
      const ownership = BackupTaskMetadata.current(
        runToken: 'run-token',
        bindingDigest: 'binding-digest',
        phase: BackupTaskPhase.primary,
      );
      final leases = _LeasePort(quarantinedCandidateKeys: {_candidateKey});
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
      );
      addTearDown(ownedService.dispose);
      when(() => mockUploadRepository.enqueueBackgroundAll(any())).thenAnswer((_) async => [true]);
      final authority = UploadBindingAuthority.fromBinding(_binding());
      UploadTask task(String taskId, String candidateKey) => UploadTask(
        taskId: taskId,
        url: 'https://photos.example/api/assets',
        filename: 'asset.jpg',
        group: kBackupGroup,
        metaData: UploadTaskMetadata(
          localAssetId: 'local',
          isLivePhotos: false,
          livePhotoVideoId: '',
          ownership: ownership,
          expectedNativeRevision: 3,
          bindingAuthority: authority,
          candidateKey: candidateKey,
        ).toJson(),
      );

      final result = await ownedService.enqueueTasks([
        task('opaque-quarantined', _candidateKey),
        task('opaque-admitted', _otherCandidateKey),
      ], ownership: ownership);

      expect(result, [false, true]);
      verify(() => mockUploadRepository.enqueueBackgroundAll(any())).called(1);
    });

    test('claims callback before await and enqueues LivePhoto child before end', () async {
      final begin = Completer<BackupExecutionLease?>();
      final enqueue = Completer<List<bool>>();
      final leases = _LeasePort(begin: begin.future);
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
      final binding = _binding();
      final entity = MockAssetEntity();
      when(
        () => mockLocalAssetRepository.getById(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => LocalAssetStub.image1);
      when(() => mockStorageRepository.getAssetEntityForAsset(LocalAssetStub.image1)).thenAnswer((_) async => entity);
      when(() => entity.isLivePhoto).thenReturn(true);
      when(
        () => mockStorageRepository.getFileForAsset(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => File('/tmp/live.heic'));
      when(
        () => mockAssetMediaRepository.getOriginalFilename(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => 'live.heic');
      when(() => mockUploadRepository.enqueueBackgroundAll(any())).thenAnswer((_) async {
        leases.events.add('enqueue');
        return enqueue.future;
      });
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
        validateBinding: (_, _) => binding,
        reconcileOwnedSuccess: (_) async {
          leases.events.add('reconcile');
          return true;
        },
        onOwnedTerminal: (success) => leases.events.add(success ? 'signal' : 'retry'),
      );
      addTearDown(ownedService.dispose);

      final callback = ownedService.handleOwnedStatusForTest(_completeLivePhotoUpdate());
      await pumpEventQueue();
      verifyNever(() => mockLocalAssetRepository.getById(any()));
      begin.complete(_lease());
      await pumpEventQueue();
      expect(leases.events, ['begin', 'beginEnqueue', 'enqueue']);
      enqueue.complete([true]);
      await callback;

      expect(leases.events, [
        'begin',
        'beginEnqueue',
        'enqueue',
        'confirmEnqueue',
        'reconcile',
        'consumeTerminal',
        'end',
        'signal',
      ]);
    });

    test('duplicate LivePhoto terminal callback enqueues exactly one child', () async {
      final leases = _LeasePort();
      final binding = _binding();
      final entity = MockAssetEntity();
      when(
        () => mockLocalAssetRepository.getById(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => LocalAssetStub.image1);
      when(() => mockStorageRepository.getAssetEntityForAsset(LocalAssetStub.image1)).thenAnswer((_) async => entity);
      when(() => entity.isLivePhoto).thenReturn(true);
      when(
        () => mockStorageRepository.getFileForAsset(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => File('/tmp/live.heic'));
      when(
        () => mockAssetMediaRepository.getOriginalFilename(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => 'live.heic');
      when(() => mockUploadRepository.enqueueBackgroundAll(any())).thenAnswer((_) async => [true]);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        validateBinding: (_, _) => binding,
        reconcileOwnedSuccess: (_) async => true,
      );
      addTearDown(ownedService.dispose);

      final update = _completeLivePhotoUpdate();
      await ownedService.handleOwnedStatusForTest(update);
      await ownedService.handleOwnedStatusForTest(update);

      verify(() => mockUploadRepository.enqueueBackgroundAll(any())).called(1);
      verify(() => mockLocalAssetRepository.getById(LocalAssetStub.image1.id)).called(1);
    });

    test('owned URLSession task requires WiFi even when cellular uploads are enabled', () async {
      when(() => mockAppSettingsService.getSetting(AppSettingsEnum.useCellularForUploadPhotos)).thenReturn(true);
      final entity = MockAssetEntity();
      when(() => entity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(LocalAssetStub.image1)).thenAnswer((_) async => entity);
      when(
        () => mockStorageRepository.getFileForAsset(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => File('/tmp/owned.heic'));
      when(
        () => mockAssetMediaRepository.getOriginalFilename(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => 'owned.heic');
      const ownership = BackupTaskMetadata.current(
        runToken: 'run-token',
        bindingDigest: 'binding-digest',
        phase: BackupTaskPhase.primary,
      );

      final task = await sut.getUploadTask(
        LocalAssetStub.image1,
        ownership: ownership,
        apiEndpoint: Uri.parse('https://photos.example/api'),
        expectedNativeRevision: 3,
      );

      expect(task?.requiresWiFi, isTrue);
    });

    test('failed reconciliation remains pending without consuming terminal or retrying upload', () async {
      final leases = _LeasePort();
      final results = [false, false, true];
      final completed = Completer<void>();
      final delays = <Duration>[];
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        validateBinding: (_, _) => _binding(),
        reconcileOwnedSuccess: (_) async {
          leases.events.add('reconcile');
          return results.removeAt(0);
        },
        reconciliationDelay: (delay) async => delays.add(delay),
        onOwnedTerminal: (success) {
          leases.events.add(success ? 'signal' : 'retry');
          if (success && !completed.isCompleted) completed.complete();
        },
        onReconciliationPending: () => leases.events.add('reconciliationPending'),
      );
      addTearDown(ownedService.dispose);

      await ownedService.handleOwnedStatusForTest(_completeOwnedUpdate());
      await completed.future;

      expect(leases.events, [
        'begin',
        'reconcile',
        'markReconciliationPending',
        'end',
        'reconciliationPending',
        'reconcile',
        'reconciliationPending',
        'reconcile',
        'completeReconciliation',
        'signal',
      ]);
      expect(delays, [const Duration(seconds: 1), const Duration(seconds: 2)]);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('restart resumes a durable pending reconciliation from completed task metadata', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final leases = _LeasePort(
        existing: _lease().copyWith(
          callbacksInFlight: 0,
          reconciliationClaims: {claim},
          candidateKeys: {claim: _candidateKey},
        ),
      );
      final completed = Completer<void>();
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) async => update.task);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        validateBinding: (_, _) => _binding(),
        reconcileOwnedSuccess: (_) async {
          leases.events.add('reconcile');
          return true;
        },
        reconciliationDelay: (_) async {},
        onOwnedTerminal: (success) {
          if (success && !completed.isCompleted) completed.complete();
        },
      );
      addTearDown(ownedService.dispose);

      await ownedService.resumePersistedReconciliations();
      await completed.future;

      expect(leases.events, ['reconcile', 'completeReconciliation']);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('restart blocks without reupload when the completed task record is unavailable', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final leases = _LeasePort(
        existing: _lease().copyWith(
          callbacksInFlight: 0,
          reconciliationClaims: {claim},
          candidateKeys: {claim: _candidateKey},
        ),
      );
      var blocked = false;
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) async => null);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        reconcileOwnedSuccess: (_) async {
          fail('A missing completed task must not attempt reconciliation');
        },
        onReconciliationBlocked: () => blocked = true,
      );
      addTearDown(ownedService.dispose);

      await ownedService.resumePersistedReconciliations();

      expect(blocked, isTrue);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('proof recovery resumes only durable reconciliation and releases the claim', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final leases = _LeasePort(existing: _lease().copyWith(callbacksInFlight: 0, reconciliationClaims: {claim}));
      var resolution = const BackupRunBindingResolution.temporarilyUnavailable();
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
      final completed = Completer<void>();
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) async => update.task);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
        resolveBinding: (_, _) => resolution,
        reconcileOwnedSuccess: (_) async {
          leases.events.add('reconcile');
          return true;
        },
        reconciliationDelay: (_) async {},
        onOwnedTerminal: (success) {
          if (success && !completed.isCompleted) completed.complete();
        },
      );
      addTearDown(ownedService.dispose);

      await ownedService.resumePersistedReconciliations();
      expect(leases.events, isEmpty);
      resolution = BackupRunBindingResolution.current(_binding());
      await ownedService.resumePersistedReconciliations();
      await completed.future;
      await pumpEventQueue();

      expect(leases.events, ['reconcile', 'completeReconciliation']);
      expect(leases.released, isTrue);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('missing completed task is quarantined after bounded recheck and subsequent edges stay inert', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final leases = _LeasePort(
        existing: _lease().copyWith(
          callbacksInFlight: 0,
          reconciliationClaims: {claim},
          candidateKeys: {claim: _candidateKey},
        ),
      );
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) async => null);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
        completedTaskRecheckDelay: (_) async {},
      );
      addTearDown(ownedService.dispose);

      await ownedService.resumePersistedReconciliations();
      await ownedService.resumePersistedReconciliations();

      expect(leases.events, ['quarantine:completedTaskMissing']);
      expect(leases.released, isTrue);
      verify(() => mockUploadRepository.completedTask(claim)).called(3);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('definitively stale binding is quarantined and subsequent edges stay inert', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final leases = _LeasePort(existing: _lease().copyWith(callbacksInFlight: 0, reconciliationClaims: {claim}));
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) async => update.task);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
        resolveBinding: (_, _) => const BackupRunBindingResolution.definitivelyStale(),
      );
      addTearDown(ownedService.dispose);

      await ownedService.resumePersistedReconciliations();
      await ownedService.resumePersistedReconciliations();

      expect(leases.events, ['quarantine:definitivelyStale']);
      expect(leases.released, isTrue);
      verify(() => mockUploadRepository.completedTask(claim)).called(1);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('edge arriving during a temporary reconciliation pass triggers exactly one rerun', () async {
      final update = _completeOwnedUpdate();
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: update.task.taskId);
      final leases = _LeasePort(existing: _lease().copyWith(callbacksInFlight: 0, reconciliationClaims: {claim}));
      final firstLookup = Completer<Task?>();
      var lookups = 0;
      var resolutions = 0;
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) {
        lookups++;
        return lookups == 1 ? firstLookup.future : Future.value(update.task);
      });
      final completed = Completer<void>();
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        resolveBinding: (_, _) => resolutions++ == 0
            ? const BackupRunBindingResolution.temporarilyUnavailable()
            : BackupRunBindingResolution.current(_binding()),
        reconcileOwnedSuccess: (_) async => true,
        reconciliationDelay: (_) async {},
        onOwnedTerminal: (success) {
          if (success && !completed.isCompleted) completed.complete();
        },
      );
      addTearDown(ownedService.dispose);

      final firstPass = ownedService.resumePersistedReconciliations();
      await pumpEventQueue();
      final edge = ownedService.resumePersistedReconciliations();
      firstLookup.complete(update.task);
      await Future.wait([firstPass, edge]);
      await completed.future;

      expect(lookups, 2);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('completed task with missing immutable metadata is quarantined instead of retried', () async {
      final original = _completeOwnedUpdate();
      final task = original.task.copyWith(metaData: '');
      final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: task.taskId);
      final leases = _LeasePort(
        existing: _lease().copyWith(
          callbacksInFlight: 0,
          reconciliationClaims: {claim},
          candidateKeys: {claim: _candidateKey},
        ),
      );
      when(() => mockUploadRepository.completedTask(claim)).thenAnswer((_) async => task);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
      );
      addTearDown(ownedService.dispose);

      await ownedService.resumePersistedReconciliations();

      expect(leases.events, ['quarantine:immutableMetadataMissing']);
      verifyNever(() => mockUploadRepository.enqueueBackgroundAll(any()));
    });

    test('progress storms never mutate durable callback counters', () async {
      final leases = _LeasePort();
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
      );
      addTearDown(ownedService.dispose);
      final task = _completeLivePhotoUpdate().task;

      for (var index = 0; index < 100; index++) {
        await ownedService.handleOwnedProgressForTest(TaskProgressUpdate(task, index / 100));
      }

      expect(leases.events, isEmpty);
    });

    test('owned primary and LivePhoto phases use distinct opaque task ids', () async {
      final ids = ['opaque-primary', 'opaque-live'];
      final entity = MockAssetEntity();
      when(() => entity.isLivePhoto).thenReturn(false);
      when(() => mockStorageRepository.getAssetEntityForAsset(LocalAssetStub.image1)).thenAnswer((_) async => entity);
      when(
        () => mockStorageRepository.getFileForAsset(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => File('/tmp/live.heic'));
      when(
        () => mockAssetMediaRepository.getOriginalFilename(LocalAssetStub.image1.id),
      ).thenAnswer((_) async => 'live.heic');
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        taskIdFactory: () => ids.removeAt(0),
      );
      addTearDown(ownedService.dispose);
      const primary = BackupTaskMetadata.current(
        runToken: 'run',
        bindingDigest: 'binding',
        phase: BackupTaskPhase.primary,
      );
      const live = BackupTaskMetadata.current(
        runToken: 'run',
        bindingDigest: 'binding',
        phase: BackupTaskPhase.livePhoto,
      );

      final primaryTask = await ownedService.getUploadTask(
        LocalAssetStub.image1,
        ownership: primary,
        expectedNativeRevision: 42,
      );
      final liveTask = await ownedService.getLivePhotoUploadTask(
        LocalAssetStub.image1,
        'remote-video',
        ownership: live,
      );

      expect(primaryTask!.taskId, 'opaque-primary');
      expect(liveTask!.taskId, 'opaque-live');
      expect({primaryTask.taskId, liveTask.taskId}, hasLength(2));
      expect(primaryTask.taskId, isNot(LocalAssetStub.image1.id));
      final taskMetadata = UploadTaskMetadata.fromJson(primaryTask.metaData);
      expect(taskMetadata.expectedNativeRevision, 42);
      expect(primaryTask.fields, isNot(contains('expectedNativeRevision')));
    });

    test('failed drain fences cancellation and retains the durable lease', () async {
      final leases = _LeasePort();
      when(() => mockStorageRepository.clearCache()).thenAnswer((_) async {});
      when(() => mockUploadRepository.cancelAndDrain(BackupExecutionArbiter.groups)).thenAnswer((_) async => false);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
      );
      addTearDown(ownedService.dispose);

      expect(await ownedService.cancel(), 1);
      expect(leases.releaseCalls, 0);
    });

    test('lease appearing after native drain is closed and drained before cancellation succeeds', () async {
      final appearedLease = _lease().copyWith(callbacksInFlight: 0);
      final leases = _LeasePort(readSequence: [null, appearedLease]);
      when(() => mockStorageRepository.clearCache()).thenAnswer((_) async {});
      when(() => mockUploadRepository.ready).thenAnswer((_) async {});
      when(() => mockUploadRepository.cancelAndDrain(BackupExecutionArbiter.groups)).thenAnswer((_) async => true);
      final registry = _DelegatingRegistry(mockUploadRepository);
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: registry);
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
      );
      addTearDown(ownedService.dispose);

      expect(await ownedService.cancel(), 0);
      expect(leases.beginClosingCalls, 1);
      expect(leases.releaseCalls, 1);
    });

    test('stale binding after admission still releases the exact quiescent lease', () async {
      final leases = _LeasePort();
      final arbiter = BackupExecutionArbiter(leases: leases, tasks: const _EmptyRegistry());
      final ownedService = BackgroundUploadService(
        mockUploadRepository,
        mockStorageRepository,
        mockLocalAssetRepository,
        mockBackupRepository,
        mockAppSettingsService,
        mockAssetMediaRepository,
        leasePort: leases,
        arbiter: arbiter,
      );
      addTearDown(ownedService.dispose);

      await ownedService.uploadBackupCandidates(
        'user-a',
        binding: _binding(),
        lease: _lease().copyWith(callbacksInFlight: 0, activityRevision: 2),
        isBindingCurrent: () => false,
      );

      expect(leases.releaseCalls, 1);
      verifyNever(() => mockStorageRepository.clearCache());
    });
  });
}

TaskStatusUpdate _completeLivePhotoUpdate() {
  const ownership = BackupTaskMetadata.current(
    runToken: 'run-token',
    bindingDigest: 'binding-digest',
    phase: BackupTaskPhase.primary,
  );
  final metadata = UploadTaskMetadata(
    localAssetId: LocalAssetStub.image1.id,
    isLivePhotos: true,
    livePhotoVideoId: '',
    ownership: ownership,
    expectedNativeRevision: 3,
    bindingAuthority: UploadBindingAuthority.fromBinding(_binding()),
    candidateKey: _candidateKey,
  );
  final task = UploadTask(
    taskId: 'opaque-primary',
    url: 'https://photos.example/api/assets',
    filename: 'live.mov',
    group: kBackupGroup,
    metaData: metadata.toJson(),
  );
  return TaskStatusUpdate(task, TaskStatus.complete, null, '{"id":"remote-video"}');
}

TaskStatusUpdate _completeOwnedUpdate() => _completeOwnedUpdateFor(
  runToken: 'run-token',
  bindingDigest: 'binding-digest',
  taskId: 'opaque-primary-complete',
  localAssetId: 'opaque-local',
);

TaskStatusUpdate _completeOwnedUpdateFor({
  required String runToken,
  required String bindingDigest,
  required String taskId,
  required String localAssetId,
}) {
  final ownership = BackupTaskMetadata.current(
    runToken: runToken,
    bindingDigest: bindingDigest,
    phase: BackupTaskPhase.primary,
  );
  final task = UploadTask(
    taskId: taskId,
    url: 'https://photos.example/api/assets',
    filename: 'asset.jpg',
    group: kBackupGroup,
    metaData: UploadTaskMetadata(
      localAssetId: localAssetId,
      isLivePhotos: false,
      livePhotoVideoId: '',
      ownership: ownership,
      expectedNativeRevision: 3,
      bindingAuthority: UploadBindingAuthority.fromBinding(_binding()),
      candidateKey: _candidateKey,
    ).toJson(),
  );
  return TaskStatusUpdate(task, TaskStatus.complete, null, '{"id":"remote"}');
}

TaskProgressUpdate _ownedProgressUpdate({
  required String runToken,
  required String bindingDigest,
  required String taskId,
  required String localAssetId,
}) {
  final task = UploadTask(
    taskId: taskId,
    url: 'https://photos.example/api/assets',
    filename: 'asset.jpg',
    group: kBackupGroup,
    metaData: UploadTaskMetadata(
      localAssetId: localAssetId,
      isLivePhotos: false,
      livePhotoVideoId: '',
      ownership: BackupTaskMetadata.current(
        runToken: runToken,
        bindingDigest: bindingDigest,
        phase: BackupTaskPhase.primary,
      ),
      expectedNativeRevision: 3,
      bindingAuthority: UploadBindingAuthority.fromBinding(_binding()),
      candidateKey: _candidateKey,
    ).toJson(),
  );
  return TaskProgressUpdate(task, 0.4);
}

BackupTaskMetadata _taskOwnership() => const BackupTaskMetadata.current(
  runToken: 'run-token',
  bindingDigest: 'binding-digest',
  phase: BackupTaskPhase.primary,
);

BackupExecutionLease _leaseWithClaims(Set<BackupTaskClaim> claims) =>
    _lease().copyWith(callbacksInFlight: 0, outstandingClaims: claims);

BackupExecutionLease _lease() => BackupExecutionLease(
  mode: BackupExecutionMode.background,
  runToken: 'run-token',
  bindingDigest: 'binding-digest',
  expiresAt: DateTime.utc(2026, 8, 11, 12),
  activityRevision: 0,
  callbacksInFlight: 1,
);

BackupRunBinding _binding() => BackupRunBinding(
  userId: 'user-a',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: 3,
  apiEndpoint: Uri.parse('https://photos.example/api'),
  canonicalOrigin: Uri.parse('https://photos.example'),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportEpoch: 1,
  transportRevision: 3,
  localLeaseRevision: 4,
);

class _LeasePort implements BackupExecutionLeasePort {
  _LeasePort({
    this.claimCallbacks = true,
    this.begin,
    this.existing,
    this.quarantinedCandidateKeys = const {},
    List<BackupExecutionLease?> readSequence = const [],
  }) : _readSequence = List.of(readSequence);

  final bool claimCallbacks;
  final Future<BackupExecutionLease?>? begin;
  BackupExecutionLease? existing;
  final Set<String> quarantinedCandidateKeys;
  final List<String> events = [];
  int releaseCalls = 0;
  int beginClosingCalls = 0;
  int orphanCallbackReleaseCalls = 0;
  bool released = false;
  final Set<BackupTaskClaim> terminalClaims = {};
  final List<BackupExecutionLease?> _readSequence;

  @override
  Future<BackupExecutionLease?> beginCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    String? operationIncarnation,
  }) async {
    events.add('begin');
    if (!claimCallbacks || terminalClaims.contains(claim)) return null;
    return begin == null ? _lease() : begin!;
  }

  @override
  Future<BackupExecutionLease?> endCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('end');
    return _lease().copyWith(callbacksInFlight: 0, activityRevision: 2);
  }

  @override
  Future<BackupExecutionLease?> markEnqueuedForTask({required String runToken, required String bindingDigest}) async {
    events.add('markEnqueued');
    return _lease().copyWith(activityRevision: 1);
  }

  @override
  Future<BackupExecutionLease?> beginEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('beginEnqueue');
    return _lease().copyWith(enqueueClaims: {claim}, activityRevision: 1);
  }

  @override
  Future<BackupExecutionLease?> beginEnqueueUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
    String? operationIncarnation,
  }) async {
    if (quarantinedCandidateKeys.contains(candidateKey)) return null;
    events.add('beginEnqueue');
    final lease = existing ?? _lease().copyWith(callbacksInFlight: 0);
    existing = lease.copyWith(
      enqueueClaims: {...lease.enqueueClaims, claim},
      candidateKeys: {...lease.candidateKeys, claim: candidateKey},
      enqueueIncarnations: operationIncarnation == null
          ? lease.enqueueIncarnations
          : {...lease.enqueueIncarnations, claim: operationIncarnation},
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<bool> allowForegroundCandidateUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required String candidateKey,
  }) async => true;

  @override
  Future<BackupExecutionLease?> confirmEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('confirmEnqueue');
    final lease = existing ?? _lease();
    existing = lease.copyWith(
      enqueueClaims: {...lease.enqueueClaims}..remove(claim),
      outstandingClaims: {...lease.outstandingClaims, claim},
      enqueueIncarnations: {...lease.enqueueIncarnations}..remove(claim),
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> abortEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('abortEnqueue');
    return _lease().copyWith(activityRevision: 2);
  }

  @override
  Future<BackupExecutionLease?> consumeTerminalForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('consumeTerminal');
    terminalClaims.add(claim);
    return _lease().copyWith(activityRevision: 3);
  }

  @override
  Future<BackupExecutionLease?> markReconciliationPendingForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('markReconciliationPending');
    final lease = existing ?? _lease();
    existing = lease.copyWith(
      outstandingClaims: {...lease.outstandingClaims}..remove(claim),
      enqueueClaims: {...lease.enqueueClaims}..remove(claim),
      reconciliationClaims: {...lease.reconciliationClaims, claim},
      enqueueIncarnations: {...lease.enqueueIncarnations}..remove(claim),
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> completeReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('completeReconciliation');
    existing = (existing ?? _lease()).copyWith(
      reconciliationClaims: const {},
      callbacksInFlight: 0,
      activityRevision: 4,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> quarantineReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
    required BackupReconciliationQuarantineCode code,
  }) async {
    final lease = existing;
    if (lease == null || !lease.reconciliationClaims.contains(claim)) return null;
    events.add('quarantine:${code.name}');
    existing = lease.copyWith(
      reconciliationClaims: {...lease.reconciliationClaims}..remove(claim),
      candidateKeys: {...lease.candidateKeys}..remove(claim),
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<Set<BackupReconciliationQuarantineEntry>> readReconciliationQuarantine() async => const {};

  @override
  Future<BackupExecutionLease?> reconcileTaskClaimsForOwner({
    required String runToken,
    required String bindingDigest,
    required Set<BackupTaskClaim> activeClaims,
  }) async => existing = (existing ?? _lease()).copyWith(outstandingClaims: activeClaims, activityRevision: 4);

  @override
  Future<BackupExecutionLease?> recoverExpiredClosingExact({
    required BackupExecutionLease expected,
    required Set<BackupTaskClaim> activeClaims,
  }) async => _lease().copyWith(outstandingClaims: activeClaims, activityRevision: 4);

  @override
  Future<BackupExecutionLease?> releaseOrphanedCallbackForTaskExact({
    required BackupExecutionLease expected,
    required BackupTaskClaim claim,
  }) async {
    orphanCallbackReleaseCalls++;
    final lease = existing;
    if (lease != expected || lease == null || !lease.callbackClaims.contains(claim) || lease.callbacksInFlight < 1) {
      return null;
    }
    existing = lease.copyWith(
      callbacksInFlight: lease.callbacksInFlight - 1,
      callbackClaims: {...lease.callbackClaims}..remove(claim),
      callbackIncarnations: {...lease.callbackIncarnations}..remove(claim),
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> beginClosingForOwner({required String runToken, required String bindingDigest}) async {
    beginClosingCalls++;
    return existing = (existing ?? _lease()).copyWith(state: BackupExecutionState.closing);
  }

  @override
  Future<BackupExecutionLease?> beginForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> endForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  }) => throw UnimplementedError();

  @override
  Future<bool> acquire(BackupExecutionLease candidate, DateTime now) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> beginCallback(BackupExecutionLease expected) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> endCallback(BackupExecutionLease expected) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> markEnqueued(BackupExecutionLease expected) => throw UnimplementedError();

  @override
  Future<BackupExecutionLease?> read() async {
    if (_readSequence.isNotEmpty) {
      existing = _readSequence.removeAt(0);
      return existing;
    }
    return released ? null : existing ?? _lease().copyWith(callbacksInFlight: 0, activityRevision: 2);
  }

  @override
  Future<bool> releaseExact(BackupExecutionLease expected) async {
    releaseCalls++;
    released = true;
    existing = null;
    return true;
  }

  @override
  Future<bool> replaceExact({required BackupExecutionLease expected, required BackupExecutionLease replacement}) =>
      throw UnimplementedError();
}

final class _ExactOwnerLeasePort extends _LeasePort {
  _ExactOwnerLeasePort(BackupExecutionLease lease, {this.consumeTerminalClaims = true, this.beforeFirstEnd})
    : super(existing: lease);

  final bool consumeTerminalClaims;
  final Future<void>? beforeFirstEnd;
  var _endCalls = 0;

  bool _matches(String runToken, String bindingDigest) {
    final lease = existing;
    return lease != null && lease.runToken == runToken && lease.bindingDigest == bindingDigest;
  }

  @override
  Future<bool> acquire(BackupExecutionLease candidate, DateTime now) async {
    if (!released && existing != null) return false;
    existing = candidate;
    released = false;
    return true;
  }

  @override
  Future<BackupExecutionLease?> beginCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    String? operationIncarnation,
  }) async {
    events.add('begin');
    final lease = existing;
    if (!_matches(runToken, bindingDigest) ||
        lease == null ||
        !lease.outstandingClaims.contains(claim) ||
        lease.callbackClaims.contains(claim)) {
      return null;
    }
    existing = lease.copyWith(
      callbacksInFlight: lease.callbacksInFlight + 1,
      callbackClaims: {...lease.callbackClaims, claim},
      callbackIncarnations: operationIncarnation == null
          ? lease.callbackIncarnations
          : {...lease.callbackIncarnations, claim: operationIncarnation},
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> consumeTerminalForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('consumeTerminal');
    final lease = existing;
    if (!consumeTerminalClaims ||
        !_matches(runToken, bindingDigest) ||
        lease == null ||
        !lease.callbackClaims.contains(claim)) {
      return null;
    }
    terminalClaims.add(claim);
    existing = lease.copyWith(
      outstandingClaims: {...lease.outstandingClaims}..remove(claim),
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }

  @override
  Future<BackupExecutionLease?> endCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) async {
    events.add('end');
    _endCalls++;
    if (_endCalls == 1) await beforeFirstEnd;
    final lease = existing;
    if (!_matches(runToken, bindingDigest) || lease == null || !lease.callbackClaims.contains(claim)) return null;
    existing = lease.copyWith(
      callbacksInFlight: lease.callbacksInFlight - 1,
      callbackClaims: {...lease.callbackClaims}..remove(claim),
      callbackIncarnations: {...lease.callbackIncarnations}..remove(claim),
      activityRevision: lease.activityRevision + 1,
    );
    return existing;
  }
}

final class _RebootTaskRegistryGateway implements BackupTaskRegistryGateway {
  _RebootTaskRegistryGateway({required this.staleTrackingRecord, required this.replayTerminal});

  final TaskRecord staleTrackingRecord;
  final void Function() replayTerminal;
  int nativeSnapshotReads = 0;
  int staleTrackingReads = 0;
  int replayCalls = 0;

  @override
  Future<void> get ready async {}

  @override
  Future<List<Task>> nativeTasks(String group) async {
    nativeSnapshotReads++;
    return const [];
  }

  @override
  Future<List<Task>> nativeTasksInGroups(Set<String> groups) async {
    nativeSnapshotReads++;
    return const [];
  }

  @override
  Future<List<TaskRecord>> trackingRecords(TaskStatus status, String group) async {
    if (status == TaskStatus.running && group == staleTrackingRecord.task.group) {
      staleTrackingReads++;
      return [staleTrackingRecord];
    }
    return const [];
  }

  @override
  Future<List<TaskRecord>> allTrackingRecords(String group) async =>
      group == staleTrackingRecord.task.group ? [staleTrackingRecord] : const [];

  @override
  Future<void> replayUndeliveredUpdates() async {
    replayCalls++;
    replayTerminal();
  }

  @override
  Future<bool> cancelNative(String group) async => true;

  @override
  Future<void> resetNative(String group) async {}

  @override
  Future<void> deleteTrackingRecords(Iterable<String> taskIds) async {}

  @override
  Future<void> repairTracking(TaskRecord record) async {}
}

final class _DelegatingRegistry implements BackupTaskRegistryPort {
  const _DelegatingRegistry(this.repository);

  final UploadRepository repository;

  @override
  Future<void> get ready => repository.ready;

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async => const [];

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) => repository.cancelAndDrain(groups);
}

final class _EmptyRegistry implements BackupTaskRegistryPort {
  const _EmptyRegistry();

  @override
  Future<void> get ready async {}

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async => const [];

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) async => true;
}
