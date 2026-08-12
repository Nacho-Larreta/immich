import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

import '../domain/service.mock.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

class _MockConnectivityApi extends Mock implements ConnectivityApi {}

class _MockCandidateGate extends Mock implements BackupExecutionLeasePort {}

void main() {
  test('quarantined automatic candidate is rejected before storage or HTTP work', () async {
    final uploads = MockUploadRepository();
    final storage = MockStorageRepository();
    final backups = MockDriftBackupRepository();
    final connectivity = _MockConnectivityApi();
    final settings = MockAppSettingsService();
    final media = MockAssetMediaRepository();
    final gate = _MockCandidateGate();
    final binding = _binding();
    final lease = _lease(binding);

    when(() => backups.getCandidates('user-a')).thenAnswer((_) async => [LocalAssetStub.image1]);
    when(() => storage.clearCache()).thenAnswer((_) async {});
    when(() => settings.getSetting(AppSettingsEnum.useCellularForUploadVideos)).thenReturn(false);
    when(() => settings.getSetting(AppSettingsEnum.useCellularForUploadPhotos)).thenReturn(false);
    when(() => connectivity.getSnapshot()).thenAnswer(
      (_) async => ConnectivityTransportSnapshot(
        availability: ConnectivityTransportAvailability.available,
        capabilities: [ConnectivityNetworkCapability.wifi],
      ),
    );
    when(
      () => gate.allowForegroundCandidateUnlessQuarantined(
        runToken: lease.runToken,
        bindingDigest: lease.bindingDigest,
        candidateKey: any(named: 'candidateKey'),
      ),
    ).thenAnswer((_) async => false);

    final service = ForegroundUploadService(
      uploads,
      storage,
      backups,
      connectivity,
      settings,
      media,
      candidateGate: gate,
      candidateKeyForAsset: (_) => 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa',
    );

    await service.uploadCandidates(
      'user-a',
      Completer<void>(),
      binding: binding,
      executionLease: lease,
      isBindingCurrent: (_) => true,
    );

    verifyNever(() => storage.getAssetEntityForAsset(LocalAssetStub.image1));
    verifyNoMoreInteractions(uploads);
  });
}

BackupRunBinding _binding() => BackupRunBinding(
  userId: 'user-a',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: 3,
  apiEndpoint: Uri.parse('https://photos.example/api'),
  canonicalOrigin: Uri.parse('https://photos.example'),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportRevision: 4,
  localLeaseRevision: 5,
);

BackupExecutionLease _lease(BackupRunBinding binding) => BackupExecutionLease(
  mode: BackupExecutionMode.foreground,
  runToken: 'run-token',
  bindingDigest: binding.digest,
  expiresAt: DateTime.utc(2026, 8, 11, 12),
  activityRevision: 1,
  callbacksInFlight: 0,
  foregroundActivityClaims: {
    ForegroundTransportClaim(
      activityId: 'foreground-run',
      bindingDigest: binding.digest,
      nativeGeneration: binding.nativeGeneration,
    ),
  },
);
