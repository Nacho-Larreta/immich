import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/providers/infrastructure/action.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockForegroundUploadService extends Mock implements ForegroundUploadService {}

class _MockActionService extends Mock implements ActionService {}

class _MockDownloadService extends Mock implements DownloadService {}

class _MockAssetService extends Mock implements AssetService {}

class _MockLocalAsset extends Mock implements LocalAsset {}

void main() {
  setUpAll(() {
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());
  });

  for (final entry in <String, ServerAccessPolicy>{
    'offline': const ServerAccessPolicy.offline(),
    'reauthentication': const ServerAccessPolicy.reauthenticationRequired(),
  }.entries) {
    test('manual upload does not reach the upload service while ${entry.key}', () async {
      final uploadService = _MockForegroundUploadService();
      final asset = _MockLocalAsset();
      when(() => asset.id).thenReturn('local');
      final container = _container(uploadService, entry.value);
      addTearDown(container.dispose);

      final result = await container.read(actionProvider.notifier).upload(ActionSource.timeline, assets: [asset]);

      expect(result.success, isFalse);
      verifyNever(
        () => uploadService.uploadManual(
          any(),
          cancelToken: any(named: 'cancelToken'),
          callbacks: any(named: 'callbacks'),
        ),
      );
    });
  }

  test('manual upload reaches the upload service online', () async {
    final uploadService = _MockForegroundUploadService();
    final asset = _MockLocalAsset();
    when(() => asset.id).thenReturn('local');
    when(
      () => uploadService.uploadManual(
        any(),
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer((_) async {});
    final container = _container(uploadService, const ServerAccessPolicy.online());
    addTearDown(container.dispose);

    final result = await container.read(actionProvider.notifier).upload(ActionSource.timeline, assets: [asset]);

    expect(result.success, isTrue);
    verify(
      () => uploadService.uploadManual(
        [asset],
        cancelToken: any(named: 'cancelToken'),
        callbacks: any(named: 'callbacks'),
      ),
    ).called(1);
  });
}

ProviderContainer _container(ForegroundUploadService uploadService, ServerAccessPolicy access) {
  return ProviderContainer(
    overrides: [
      foregroundUploadServiceProvider.overrideWithValue(uploadService),
      actionServiceProvider.overrideWithValue(_MockActionService()),
      downloadServiceProvider.overrideWithValue(_MockDownloadService()),
      assetServiceProvider.overrideWithValue(_MockAssetService()),
      serverAccessProvider.overrideWithValue(access),
    ],
  );
}
