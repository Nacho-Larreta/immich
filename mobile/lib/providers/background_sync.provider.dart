import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/background_task_context_source.interface.dart';
import 'package:immich_mobile/domain/models/background_task.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/backup_sync.model.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/infrastructure/adapters/background_sync/isolate_background_task_runner.dart';
import 'package:immich_mobile/infrastructure/adapters/background_sync/background_task_context_source_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/providers/backup/backup_sync_error.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

final backgroundTaskContextSourceProvider = Provider<BackgroundTaskContextSourcePort>((ref) {
  if (NetworkRepository.isAttachedWorker) {
    return NativeBackgroundTaskContextSourceAdapter(
      readEvidence: () => NetworkRepository.serverAccessEvidence,
      readAuthenticatedSession: () => (
        ready: Store.tryGet(StoreKey.authenticatedSessionReady) == true,
        token: Store.tryGet(StoreKey.accessToken),
        userId: Store.tryGet(StoreKey.currentUser)?.id,
        endpoint: Store.tryGet(StoreKey.serverEndpoint),
        policy: Store.tryGet(StoreKey.serverEndpointSchemePolicy),
      ),
    );
  }
  return ReachabilityBackgroundTaskContextSourceAdapter(
    () => ref.read(serverReachabilityStateProvider),
    () => ref.read(currentUserProvider)?.id,
  );
});

final Provider<BackgroundSyncManager> backgroundSyncProvider = Provider<BackgroundSyncManager>((ref) {
  final syncStatusNotifier = ref.read(syncStatusProvider.notifier);
  final contextSource = ref.read(backgroundTaskContextSourceProvider);

  final manager = BackgroundSyncManager(
    taskRunner: const IsolateBackgroundTaskRunner(),
    remoteTaskContext: () {
      return contextSource.capture() ?? (throw const BackgroundTaskContextChanged());
    },
    onRemoteSyncStart: () {
      syncStatusNotifier.startRemoteSync();
      ref.read(backupSyncErrorProvider.notifier).state = BackupError.none;
    },
    onRemoteSyncComplete: (isSuccess) {
      syncStatusNotifier.completeRemoteSync();
      ref.read(backupSyncErrorProvider.notifier).state = isSuccess == true ? BackupError.none : BackupError.syncFailed;
    },
    onRemoteSyncError: syncStatusNotifier.errorRemoteSync,
    onRemoteSyncCancelled: syncStatusNotifier.cancelRemoteSync,
    onLocalSyncStart: syncStatusNotifier.startLocalSync,
    onLocalSyncComplete: syncStatusNotifier.completeLocalSync,
    onLocalSyncError: syncStatusNotifier.errorLocalSync,
    onLocalSyncCancelled: syncStatusNotifier.cancelLocalSync,
    onHashingStart: syncStatusNotifier.startHashJob,
    onHashingComplete: syncStatusNotifier.completeHashJob,
    onHashingError: syncStatusNotifier.errorHashJob,
    onHashingCancelled: syncStatusNotifier.cancelHashJob,
    onCloudIdSyncStart: syncStatusNotifier.startCloudIdSync,
    onCloudIdSyncComplete: syncStatusNotifier.completeCloudIdSync,
    onCloudIdSyncError: syncStatusNotifier.errorCloudIdSync,
    onCloudIdSyncCancelled: syncStatusNotifier.cancelCloudIdSync,
  );
  ref.onDispose(() => consumeBackgroundSyncTap(manager.cancel()));
  return manager;
});
