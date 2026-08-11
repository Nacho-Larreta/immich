import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/sync_status.provider.dart';

final backgroundSyncProvider = Provider<BackgroundSyncManager>((ref) {
  final syncStatusNotifier = ref.read(syncStatusProvider.notifier);

  final manager = BackgroundSyncManager(
    onRemoteSyncStart: () {
      syncStatusNotifier.startRemoteSync();
      final backupProvider = ref.read(driftBackupProvider.notifier);
      if (backupProvider.mounted) {
        backupProvider.updateError(BackupError.none);
      }
    },
    onRemoteSyncComplete: (isSuccess) {
      syncStatusNotifier.completeRemoteSync();
      final backupProvider = ref.read(driftBackupProvider.notifier);
      if (backupProvider.mounted) {
        backupProvider.updateError(isSuccess == true ? BackupError.none : BackupError.syncFailed);
      }
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
