import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_authority.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_outbox.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_source.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_staging.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_submission.interface.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_transport.interface.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/manual_upload_coordinator.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/ios_backup_operation_lifetime_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/background_downloader_manual_transport.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/current_session_manual_authority_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/manual_upload_staging_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/photo_manager_manual_source_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_outbox.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/manual_upload_owner_drain.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:logging/logging.dart';
import 'package:uuid/uuid.dart';

final manualUploadRootEnabledProvider = Provider<bool>(
  (_) => CurrentPlatform.isIOS && !NetworkRepository.isAttachedWorker,
);

final manualUploadOwnerDrainProvider = Provider<ManualUploadOwnerDrain>((_) => ManualUploadOwnerDrain());

final manualUploadDatabaseProvider = Provider<ManualUploadDatabase>((ref) {
  if (!ref.read(manualUploadRootEnabledProvider)) throw StateError('Manual outbox belongs to the root iOS engine');
  final database = ManualUploadDatabase();
  final owners = ref.read(manualUploadOwnerDrainProvider);
  ref.onDispose(() => _releaseAfterOwners(owners, database.close));
  return database;
});

final manualUploadOutboxProvider = Provider<ManualUploadOutbox>(
  (ref) => DriftManualUploadOutbox(ref.read(manualUploadDatabaseProvider)),
);

final manualUploadStagingProvider = Provider<ManualUploadStagingPort>((_) => ManualUploadStagingAdapter());
final manualUploadLifetimeProvider = Provider<BackupOperationLifetimePort>(
  (_) => const IosBackupOperationLifetimeAdapter(),
);

final manualUploadSourceProvider = Provider<ManualUploadSourcePort>(
  (ref) => PhotoManagerManualSourceAdapter(
    ref.read(localAssetRepository),
    ref.read(storageRepositoryProvider),
    ref.read(assetMediaRepositoryProvider),
  ),
);

final manualUploadAuthorityProvider = Provider<ManualUploadAuthoritySourcePort>((ref) {
  return CurrentSessionManualAuthorityAdapter(
    readDestination: () {
      if (Store.tryGet(StoreKey.authenticatedSessionReady) != true) return null;
      final user = Store.tryGet(StoreKey.currentUser);
      final server = Store.tryGet(StoreKey.serverUrl);
      if (user == null || server == null || server.isEmpty) return null;
      return ManualUploadDestination(serverUrl: server, userId: user.id);
    },
    readRegisteredEndpoints: () => ApiService.getServerUrls().map(Uri.tryParse).whereType<Uri>().toSet(),
    captureBinding: () => ref.read(backupRunBindingSourceProvider).capture(),
  );
});

final manualUploadTransportProvider = Provider<ManualUploadTransportPort>((ref) {
  final transport = BackgroundDownloaderManualTransport(
    uploadRepository: ref.read(uploadRepositoryProvider),
    lifetime: ref.read(manualUploadLifetimeProvider),
    staging: ref.read(manualUploadStagingProvider),
  );
  final owners = ref.read(manualUploadOwnerDrainProvider);
  ref.onDispose(() => _releaseAfterOwners(owners, () async => transport.dispose()));
  return transport;
});

final manualUploadResumeSignalProvider = Provider<StreamController<void>>((ref) {
  final signals = StreamController<void>.broadcast();
  ref.onDispose(() => unawaited(signals.close()));
  return signals;
});

final manualUploadConfirmedProjectionProvider = Provider<Future<void> Function(ManualUploadIntent)>((ref) {
  return (intent) async {
    final authority = ref.read(manualUploadAuthorityProvider).captureAuthorized();
    if (authority == null || authority.destination != intent.destination) {
      throw StateError('Manual upload projection is waiting for its authorized destination');
    }
    if (!await ref.read(backgroundSyncProvider).syncRemoteForBinding(authority.binding)) {
      throw StateError('Manual upload projection is waiting for remote sync');
    }
  };
});

final manualUploadCoordinatorProvider = Provider<ManualUploadCoordinator>((ref) {
  if (!ref.read(manualUploadRootEnabledProvider)) throw StateError('Manual coordinator belongs to the root iOS engine');
  final transport = ref.read(manualUploadTransportProvider);
  final progress = ref.read(assetUploadProgressProvider.notifier);
  final coordinator = ManualUploadCoordinator(
    outbox: ref.read(manualUploadOutboxProvider),
    staging: ref.read(manualUploadStagingProvider),
    source: ref.read(manualUploadSourceProvider),
    authority: ref.read(manualUploadAuthorityProvider),
    transport: transport,
    lifetime: ref.read(manualUploadLifetimeProvider),
    newId: const Uuid().v4,
    now: DateTime.now,
    onConfirmed: ref.read(manualUploadConfirmedProjectionProvider),
    onProgress: (intent, value) => progress.setProgress(intent.localAssetId, value),
    onTerminal: (intent) => progress.remove(intent.localAssetId),
  );
  final stop = ref.read(manualUploadOwnerDrainProvider).register(coordinator.stop);
  final logger = Logger('ManualUploadLifecycle');
  Future<void> replayAndPump(bool replay) async {
    if (replay) await transport.replayUndeliveredUpdates();
    await coordinator.pump();
  }

  void wake({bool replay = false}) {
    unawaited(
      replayAndPump(replay).catchError((Object error, StackTrace stack) {
        logger.warning('manual_upload_wakeup_failed', error, stack);
      }),
    );
  }

  final resumes = ref.read(manualUploadResumeSignalProvider).stream.listen((_) => wake(replay: true));
  ref.listen(serverReachabilityStateProvider, (_, next) {
    if (next.phase == ReachabilityPhase.online && next.serverAccess?.isCurrent == true) wake();
  });
  ref.onDispose(() {
    unawaited(resumes.cancel());
    unawaited(stop());
  });
  return coordinator..start();
});

final manualUploadSubmissionProvider = Provider<ManualUploadSubmissionPort>(
  (ref) => ref.read(manualUploadCoordinatorProvider),
);

final manualUploadStartupProvider = Provider<void>((ref) {
  if (ref.read(manualUploadRootEnabledProvider)) ref.read(manualUploadCoordinatorProvider);
});

void _releaseAfterOwners(ManualUploadOwnerDrain owners, Future<void> Function() release) {
  unawaited(
    () async {
      await owners.drain();
      await release();
    }().catchError((Object error, StackTrace stack) {
      Logger('ManualUploadLifecycle').warning('manual_upload_resource_release_failed', error, stack);
    }),
  );
}
