import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:logging/logging.dart';

import '../domain/service.mock.dart';
import '../fixtures/asset.stub.dart';
import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

class _MockConnectivityMonitor extends Mock implements ConnectivitySnapshotMonitorPort {}

class _MockCandidateGate extends Mock implements BackupExecutionLeasePort {}

void main() {
  final preCandidateCases = <({String name, BackupTransportSnapshot snapshot, ForegroundUploadGateReason reason})>[
    (
      name: 'non-wifi',
      snapshot: const BackupTransportSnapshot(
        available: true,
        capabilities: {BackupNetworkCapability.cellular},
        monitorEpoch: 1,
        revision: 4,
      ),
      reason: ForegroundUploadGateReason.noWifi,
    ),
    (
      name: 'unavailable evidence',
      snapshot: const BackupTransportSnapshot(available: false, capabilities: {}, monitorEpoch: 1, revision: 4),
      reason: ForegroundUploadGateReason.evidenceUnavailable,
    ),
    (
      name: 'fresh cursor',
      snapshot: const BackupTransportSnapshot(
        available: true,
        capabilities: {BackupNetworkCapability.wifi},
        monitorEpoch: 1,
        revision: 5,
      ),
      reason: ForegroundUploadGateReason.transportCursorChanged,
    ),
  ];

  for (final testCase in preCandidateCases) {
    test('${testCase.name} returns one opaque pre-candidate denial', () async {
      final uploads = MockUploadRepository();
      final storage = MockStorageRepository();
      final backups = MockDriftBackupRepository();
      final connectivity = _MockConnectivityMonitor();
      final settings = MockAppSettingsService();
      final media = MockAssetMediaRepository();
      final logRecords = <LogRecord>[];
      final subscription = Logger('ForegroundUploadService').onRecord.listen(logRecords.add);
      addTearDown(subscription.cancel);
      when(() => connectivity.readCurrentSnapshot()).thenAnswer((_) async => testCase.snapshot);
      final service = ForegroundUploadService(uploads, storage, backups, connectivity, settings, media);

      final result = await service.uploadCandidates(
        'user-a',
        Completer<void>(),
        binding: _binding(),
        isBindingCurrent: (_) => true,
      );

      expect(
        result.denial,
        ForegroundUploadGateDenial(stage: ForegroundUploadGateStage.preCandidate, reason: testCase.reason),
      );
      expect(logRecords.map((record) => record.message), [
        'foreground_upload_gate_denied_preCandidate_${testCase.reason.name}',
      ]);
      verifyNever(() => backups.getCandidates(any()));
      verifyNoMoreInteractions(storage);
      verifyNoMoreInteractions(uploads);
    });
  }

  for (final sequential in [false, true]) {
    test('fresh N plus 1 denies ${sequential ? 'sequential' : 'pooled'} upload before storage', () async {
      final uploads = MockUploadRepository();
      final storage = MockStorageRepository();
      final backups = MockDriftBackupRepository();
      final connectivity = _MockConnectivityMonitor();
      final settings = MockAppSettingsService();
      final media = MockAssetMediaRepository();
      final logRecords = <LogRecord>[];
      final subscription = Logger('ForegroundUploadService').onRecord.listen(logRecords.add);
      addTearDown(subscription.cancel);
      final snapshots = [
        const BackupTransportSnapshot(
          available: true,
          capabilities: {BackupNetworkCapability.wifi},
          monitorEpoch: 1,
          revision: 4,
        ),
        const BackupTransportSnapshot(
          available: true,
          capabilities: {BackupNetworkCapability.wifi},
          monitorEpoch: 1,
          revision: 5,
        ),
      ];
      when(() => backups.getCandidates('user-a')).thenAnswer((_) async => [LocalAssetStub.image1]);
      when(() => connectivity.readCurrentSnapshot()).thenAnswer((_) async => snapshots.removeAt(0));
      final service = ForegroundUploadService(uploads, storage, backups, connectivity, settings, media);

      final result = await service.uploadCandidates(
        'user-a',
        Completer<void>(),
        useSequentialUpload: sequential,
        binding: _binding(),
        isBindingCurrent: (_) => true,
      );

      expect(result.denial?.stage, ForegroundUploadGateStage.preStorage);
      expect(result.denial?.reason, ForegroundUploadGateReason.transportCursorChanged);
      expect(
        logRecords.map((record) => record.message).where((message) => message.startsWith('foreground_upload_gate_')),
        ['foreground_upload_gate_denied_preStorage_transportCursorChanged'],
      );
      verifyNever(storage.clearCache);
      verifyNever(() => storage.getAssetEntityForAsset(LocalAssetStub.image1));
      verifyNoMoreInteractions(uploads);
    });
  }

  test('quarantined automatic candidate is rejected before storage or HTTP work', () async {
    final uploads = MockUploadRepository();
    final storage = MockStorageRepository();
    final backups = MockDriftBackupRepository();
    final connectivity = _MockConnectivityMonitor();
    final settings = MockAppSettingsService();
    final media = MockAssetMediaRepository();
    final gate = _MockCandidateGate();
    final binding = _binding();
    final lease = _lease(binding);

    when(() => backups.getCandidates('user-a')).thenAnswer((_) async => [LocalAssetStub.image1]);
    when(() => storage.clearCache()).thenAnswer((_) async {});
    when(() => settings.getSetting(AppSettingsEnum.useCellularForUploadVideos)).thenReturn(false);
    when(() => settings.getSetting(AppSettingsEnum.useCellularForUploadPhotos)).thenReturn(false);
    when(() => connectivity.readCurrentSnapshot()).thenAnswer(
      (_) async => const BackupTransportSnapshot(
        available: true,
        capabilities: {BackupNetworkCapability.wifi},
        monitorEpoch: 1,
        revision: 4,
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

    final result = await service.uploadCandidates(
      'user-a',
      Completer<void>(),
      binding: binding,
      executionLease: lease,
      isBindingCurrent: (_) => true,
    );

    expect(result.completed, isTrue);
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
  transportEpoch: 1,
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
