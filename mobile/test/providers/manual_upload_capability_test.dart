import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_authority.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_submission.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_result.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/manual_upload.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

const _destination = ManualUploadDestination(serverUrl: 'https://photos.example/api', userId: 'user-1');

class _MockSubmission extends Mock implements ManualUploadSubmissionPort {}

class _MockActionService extends Mock implements ActionService {}

class _MockDownloadService extends Mock implements DownloadService {}

class _MockAssetService extends Mock implements AssetService {}

class _MockLocalAsset extends Mock implements LocalAsset {}

class _MockForegroundUploadService extends Mock implements ForegroundUploadService {}

final class _Authority implements ManualUploadAuthoritySourcePort {
  const _Authority();

  @override
  ManualUploadDestination? currentDestination() => _destination;

  @override
  ManualUploadAuthority? captureAuthorized() => null;
}

void main() {
  setUp(() => debugDefaultTargetPlatformOverride = TargetPlatform.iOS);
  tearDown(() => debugDefaultTargetPlatformOverride = null);
  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());
  });

  test('offline manual tap commits intent and reports queued, never uploaded', () async {
    final submission = _MockSubmission();
    final asset = _MockLocalAsset();
    when(() => asset.id).thenReturn('local-1');
    when(() => submission.submit(any())).thenAnswer(
      (invocation) async => [
        for (final selection in invocation.positionalArguments.single as List<ManualUploadSelection>)
          ManualUploadIntent.fromSelection(selection),
      ],
    );
    final container = _container(submission, const ServerAccessPolicy.offline());
    addTearDown(container.dispose);

    final result = await container.read(actionProvider.notifier).upload(ActionSource.timeline, assets: [asset]);

    expect(result.success, isTrue);
    expect(result.count, 0);
    expect(result.acceptedCount, 1);
    expect(result.pendingCount, 1);
    expect(container.read(assetUploadProgressProvider), {'local-1': 0});
    final selections = verify(() => submission.submit(captureAny())).captured.single as List<ManualUploadSelection>;
    expect(selections.single.destination, _destination);
    expect(selections.single.deviceId, 'phone');
  });

  test('storage failure before durable acknowledgment leaves upload unaccepted and no fake progress', () async {
    final submission = _MockSubmission();
    final asset = _MockLocalAsset();
    when(() => asset.id).thenReturn('local-1');
    final pendingCommit = Completer<List<ManualUploadIntent>>();
    when(() => submission.submit(any())).thenAnswer((_) => pendingCommit.future);
    final container = _container(submission, const ServerAccessPolicy.online());
    addTearDown(container.dispose);

    final resultFuture = container.read(actionProvider.notifier).upload(ActionSource.timeline, assets: [asset]);
    expect(container.read(assetUploadProgressProvider), isEmpty);
    pendingCommit.completeError(StateError('disk-full'));
    final result = await resultFuture;

    expect(result.success, isFalse);
    expect(result.acceptedCount, 0);
    expect(result.pendingCount, 1);
    expect(container.read(assetUploadProgressProvider), isEmpty);
  });

  test('Android preserves foreground upload, progress and confirmed success semantics', () async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final submission = _MockSubmission();
    final foreground = _MockForegroundUploadService();
    final asset = _MockLocalAsset();
    when(() => asset.id).thenReturn('local-1');
    when(
      () => foreground.uploadManual(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer(
      (_) async => const ManualUploadResult([
        ManualAssetUploadOutcome(
          localAssetId: 'local-1',
          state: ManualAssetUploadState.succeeded,
          remoteAssetId: 'remote',
        ),
      ]),
    );
    final container = ProviderContainer(
      overrides: [
        manualUploadSubmissionProvider.overrideWithValue(submission),
        foregroundUploadServiceProvider.overrideWithValue(foreground),
        actionServiceProvider.overrideWithValue(_MockActionService()),
        downloadServiceProvider.overrideWithValue(_MockDownloadService()),
        assetServiceProvider.overrideWithValue(_MockAssetService()),
        serverAccessProvider.overrideWithValue(const ServerAccessPolicy.online()),
      ],
    );
    addTearDown(container.dispose);

    final result = await container.read(actionProvider.notifier).upload(ActionSource.timeline, assets: [asset]);

    expect(result.success, isTrue);
    expect(result.count, 1);
    expect(result.acceptedCount, 0);
    verifyNever(() => submission.submit(any()));
    verify(
      () => foreground.uploadManual(
        [asset],
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).called(1);
  });
}

ProviderContainer _container(ManualUploadSubmissionPort submission, ServerAccessPolicy access) => ProviderContainer(
  overrides: [
    manualUploadSubmissionProvider.overrideWithValue(submission),
    manualUploadAuthorityProvider.overrideWithValue(const _Authority()),
    manualUploadDeviceIdProvider.overrideWithValue('phone'),
    actionServiceProvider.overrideWithValue(_MockActionService()),
    downloadServiceProvider.overrideWithValue(_MockDownloadService()),
    assetServiceProvider.overrideWithValue(_MockAssetService()),
    serverAccessProvider.overrideWithValue(access),
  ],
);
