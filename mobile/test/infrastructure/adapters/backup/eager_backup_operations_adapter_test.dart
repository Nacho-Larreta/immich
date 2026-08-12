import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/eager_backup_operations_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockLeasePort extends Mock implements BackupExecutionLeasePort {}

class _MockTaskRegistry extends Mock implements BackupTaskRegistryPort {}

class _MockBackups extends Mock implements DriftBackupRepository {}

class _MockSynchronization extends Mock implements BackgroundSyncManager {}

class _MockUploads extends Mock implements ForegroundUploadService {}

class _MockBindings extends Mock implements BackupRunBindingSourcePort {}

void main() {
  setUpAll(() {
    registerFallbackValue(_lease('fallback'));
    registerFallbackValue(
      const ForegroundTransportClaim(activityId: 'fallback', bindingDigest: 'fallback', nativeGeneration: 0),
    );
    registerFallbackValue(Completer<void>());
    registerFallbackValue(const UploadCallbacks());
  });

  test('transport denial skips reconciliation and releases the lease exactly once', () async {
    final binding = _binding();
    final leases = _MockLeasePort();
    final tasks = _MockTaskRegistry();
    final backups = _MockBackups();
    final synchronization = _MockSynchronization();
    final uploads = _MockUploads();
    final bindings = _MockBindings();
    BackupExecutionLease? currentLease;

    when(() => tasks.ready).thenAnswer((_) async {});
    when(() => tasks.snapshot(BackupExecutionArbiter.groups)).thenAnswer((_) async => []);
    when(leases.read).thenAnswer((_) async => currentLease);
    when(() => leases.acquire(any(), any())).thenAnswer((invocation) async {
      currentLease = invocation.positionalArguments.first as BackupExecutionLease;
      return true;
    });
    when(
      () => leases.beginForegroundActivityForOwner(
        runToken: any(named: 'runToken'),
        bindingDigest: any(named: 'bindingDigest'),
        claim: any(named: 'claim'),
      ),
    ).thenAnswer((invocation) async {
      final claim = invocation.namedArguments[#claim] as ForegroundTransportClaim;
      currentLease = currentLease!.copyWith(foregroundActivityClaims: {claim});
      return currentLease;
    });
    when(
      () => leases.endForegroundActivityForOwner(
        runToken: any(named: 'runToken'),
        bindingDigest: any(named: 'bindingDigest'),
        claim: any(named: 'claim'),
      ),
    ).thenAnswer((_) async {
      currentLease = currentLease!.copyWith(foregroundActivityClaims: const {});
      return currentLease;
    });
    when(() => leases.releaseExact(any())).thenAnswer((_) async {
      currentLease = null;
      return true;
    });
    when(() => bindings.isCurrent(binding)).thenReturn(true);
    when(
      () => uploads.uploadCandidates(
        binding.userId,
        any(),
        binding: binding,
        executionLease: any(named: 'executionLease'),
        isBindingCurrent: any(named: 'isBindingCurrent'),
        callbacks: any(named: 'callbacks'),
      ),
    ).thenAnswer(
      (_) async => const ForegroundUploadResult.denied(
        ForegroundUploadGateDenial(
          stage: ForegroundUploadGateStage.preStorage,
          reason: ForegroundUploadGateReason.transportCursorChanged,
        ),
      ),
    );

    final adapter = EagerBackupOperationsAdapter(
      readUserId: () => binding.userId,
      backups: backups,
      synchronization: synchronization,
      uploads: uploads,
      arbiter: BackupExecutionArbiter(leases: leases, tasks: tasks, tokenFactory: () => 'run-token'),
      bindings: bindings,
      heartbeatInterval: const Duration(hours: 1),
    );

    final outcome = await adapter.upload(binding, EagerBackupCancellation());

    expect(outcome, EagerBackupUploadOutcome.transportCursorChanged);
    verifyNever(() => synchronization.syncRemoteForBinding(binding));
    verify(() => leases.releaseExact(any())).called(1);
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

BackupExecutionLease _lease(String digest) => BackupExecutionLease(
  mode: BackupExecutionMode.foreground,
  runToken: 'run-token',
  bindingDigest: digest,
  expiresAt: DateTime.utc(2026, 8, 12, 12),
  activityRevision: 0,
  callbacksInFlight: 0,
);
