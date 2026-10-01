import 'dart:convert';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_task_builder.dart';

void main() {
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  final builder = ManualUploadTaskBuilder(
    splitPath: (_) async => (BaseDirectory.applicationSupport, 'manual-upload-staging-v1/intent-1', 'primary.heic'),
  );
  final authorizedEndpoints = {Uri.parse('https://photos.example/api')};

  test('manual native task persists no credentials and binds current engine/revision', () async {
    final intent = _intent(remoteIds: const {ManualUploadComponent.motion: 'motion-remote'});
    final task = await builder.build(
      intent: intent,
      staged: intent.stagedComponents[ManualUploadComponent.primary]!,
      asset: _asset(),
      binding: _binding(),
      currentDestination: intent.destination,
      authorizedEndpoints: authorizedEndpoints,
      absolutePath: '/private/app-support/manual-upload-staging-v1/intent-1/primary.heic',
    );

    expect(task.group, kManualUploadGroup);
    expect(task.taskId, 'opaque-task-1');
    expect(task.retries, 0);
    expect(task.headers, isEmpty);
    final persisted = Task.createFromJsonString(jsonEncode(task.toJson())) as UploadTask;
    expect(persisted.headers, isEmpty);
    expect(persisted.metaData, task.metaData);
    expect(task.fields, containsPair('duration', '0:00:25.000000'));
    expect(task.fields, containsPair('fileCreatedAt', _asset().createdAt.toUtc().toIso8601String()));
    expect(task.fields, containsPair('fileModifiedAt', _asset().updatedAt.toUtc().toIso8601String()));
    expect(task.fields, containsPair('deviceAssetId', 'asset-1'));
    expect(task.fields, containsPair('deviceId', 'device-1'));
    expect(task.fields, containsPair('isFavorite', 'true'));
    final metadata = jsonDecode(task.metaData) as Map<String, dynamic>;
    expect(metadata, containsPair('operationIncarnation', 'ios-engine-v1:engine:1'));
    expect(metadata, containsPair('expectedNativeRevision', 7));
    expect(metadata, containsPair('bindingDigest', _binding().digest));
    expect(metadata, containsPair('intentId', 'intent-1'));
    expect(metadata, containsPair('attemptGeneration', 1));
    expect(metadata, isNot(contains('authorization')));
    expect(task.fields['metadata'], contains('icloud-id'));
  });

  test('motion task never carries cloud metadata and still carries confirmed motion ID', () async {
    final motionAttempt = _attempt(ManualUploadComponent.motion);
    final motionIntent = _intent(attempt: motionAttempt);
    final motionTask = await builder.build(
      intent: motionIntent,
      staged: motionIntent.stagedComponents[ManualUploadComponent.motion]!,
      asset: _asset(),
      binding: _binding(),
      currentDestination: motionIntent.destination,
      authorizedEndpoints: authorizedEndpoints,
      absolutePath: '/private/app-support/manual-upload-staging-v1/intent-1/motion.mov',
    );
    expect(motionTask.fields.containsKey('metadata'), isFalse);
    expect(motionTask.fields.containsKey('livePhotoVideoId'), isFalse);

    final primaryIntent = _intent(remoteIds: const {ManualUploadComponent.motion: 'motion-remote'});
    final primaryTask = await builder.build(
      intent: primaryIntent,
      staged: primaryIntent.stagedComponents[ManualUploadComponent.primary]!,
      asset: _asset(),
      binding: _binding(),
      currentDestination: primaryIntent.destination,
      authorizedEndpoints: authorizedEndpoints,
      absolutePath: '/private/app-support/manual-upload-staging-v1/intent-1/primary.heic',
    );
    expect(primaryTask.fields, containsPair('livePhotoVideoId', 'motion-remote'));
    expect(primaryTask.fields['metadata'], contains('icloud-id'));
  });

  test('changed account or native request revision cannot create an old-authority task', () async {
    final intent = _intent(remoteIds: const {ManualUploadComponent.motion: 'motion-remote'});
    Future<UploadTask> build({required BackupRunBinding binding, required ManualUploadDestination destination}) =>
        builder.build(
          intent: intent,
          staged: intent.stagedComponents[ManualUploadComponent.primary]!,
          asset: _asset(),
          binding: binding,
          currentDestination: destination,
          authorizedEndpoints: authorizedEndpoints,
          absolutePath: '/private/app-support/manual-upload-staging-v1/intent-1/primary.heic',
        );

    await expectLater(
      build(
        binding: _binding(),
        destination: const ManualUploadDestination(serverUrl: 'https://other.example/api', userId: 'user-2'),
      ),
      throwsStateError,
    );
    await expectLater(
      build(binding: _binding(nativeGeneration: 8), destination: _intent().destination),
      throwsStateError,
    );
    await expectLater(
      build(
        binding: _binding(apiEndpoint: Uri.parse('https://other.example/api')),
        destination: intent.destination,
      ),
      throwsStateError,
    );
  });

  test('task builder rejects a same-basename path not published by this intent', () async {
    final intent = _intent(remoteIds: const {ManualUploadComponent.motion: 'motion-remote'});
    await expectLater(
      builder.build(
        intent: intent,
        staged: const ManualUploadStagedComponent(
          component: ManualUploadComponent.primary,
          relativePath: 'foreign-intent/primary.heic',
          fileName: 'original.heic',
        ),
        asset: _asset(),
        binding: _binding(),
        currentDestination: intent.destination,
        authorizedEndpoints: authorizedEndpoints,
        absolutePath: '/private/app-support/manual-upload-staging-v1/foreign-intent/primary.heic',
      ),
      throwsStateError,
    );
  });
}

ManualUploadAttempt _attempt(ManualUploadComponent component) => ManualUploadAttempt(
  taskId: 'opaque-task-1',
  generation: 1,
  component: component,
  operationIdentity: 'ios-engine-v1:engine:1',
  nativeGeneration: 7,
);

ManualUploadIntent _intent({ManualUploadAttempt? attempt, Map<ManualUploadComponent, String> remoteIds = const {}}) =>
    ManualUploadIntent(
      id: 'intent-1',
      destination: const ManualUploadDestination(serverUrl: 'https://photos.example/api', userId: 'user-1'),
      deviceId: 'device-1',
      localAssetId: 'asset-1',
      createdAt: DateTime.utc(2026, 1),
      version: 3,
      status: ManualUploadIntentStatus.uploading,
      requiredComponents: const {ManualUploadComponent.motion, ManualUploadComponent.primary},
      stagedComponents: const {
        ManualUploadComponent.motion: ManualUploadStagedComponent(
          component: ManualUploadComponent.motion,
          relativePath: 'intent-1/motion.mov',
          fileName: 'original.mov',
        ),
        ManualUploadComponent.primary: ManualUploadStagedComponent(
          component: ManualUploadComponent.primary,
          relativePath: 'intent-1/primary.heic',
          fileName: 'original.heic',
        ),
      },
      remoteIds: remoteIds,
      attemptGeneration: 1,
      currentAttempt: attempt ?? _attempt(ManualUploadComponent.primary),
    );

LocalAsset _asset() => LocalAsset(
  id: 'asset-1',
  name: 'original.heic',
  type: AssetType.video,
  createdAt: DateTime.utc(2025, 3, 4),
  updatedAt: DateTime.utc(2025, 3, 5),
  durationMs: 25000,
  cloudId: 'icloud-id',
  isFavorite: true,
  playbackStyle: AssetPlaybackStyle.livePhoto,
  isEdited: false,
);

BackupRunBinding _binding({int nativeGeneration = 7, Uri? apiEndpoint}) => BackupRunBinding(
  userId: 'user-1',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: nativeGeneration,
  apiEndpoint: apiEndpoint ?? Uri.parse('https://photos.example/api'),
  canonicalOrigin: Uri.parse((apiEndpoint ?? Uri.parse('https://photos.example/api')).origin),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportEpoch: 1,
  transportRevision: 2,
  localLeaseRevision: 3,
);
