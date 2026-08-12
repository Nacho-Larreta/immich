import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/eager_backup_coordinator.dart';
import 'package:immich_mobile/domain/services/backup_disable_barrier.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/eager_backup_operations_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/photo_manager_change_observer_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_execution.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup_signal.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';

final backupDisableBarrierProvider = Provider<BackupDisableBarrier>((ref) {
  return BackupDisableBarrier(() async => await ref.read(backgroundUploadServiceProvider).cancel() == 0);
});

final eagerBackupStateProvider = StreamProvider<EagerBackupState>((ref) async* {
  final coordinator = ref.watch(eagerBackupCoordinatorProvider);
  yield coordinator.state;
  yield* coordinator.states;
});

final eagerBackupStartupProvider = Provider<void>((ref) {
  ref.read(eagerBackupCoordinatorProvider);
});

final eagerBackupCoordinatorProvider = Provider<EagerBackupCoordinator>((ref) {
  final backups = ref.read(backupRepositoryProvider);
  final coordinator = EagerBackupCoordinator(
    operations: EagerBackupOperationsAdapter(
      readUserId: () => ref.read(currentUserProvider)?.id,
      backups: backups,
      synchronization: ref.read(backgroundSyncProvider),
      uploads: ref.read(foregroundUploadServiceProvider),
      arbiter: ref.read(backupExecutionArbiterProvider),
      bindings: ref.read(backupRunBindingSourceProvider),
    ),
  );
  final connectivity = ref.read(nativeConnectivityMonitorProvider) as ConnectivitySnapshotMonitorPort;
  final photoObserver = PhotoManagerChangeObserverAdapter(
    onChanged: () => coordinator.signal(EagerBackupTrigger.photoLibraryChanged),
  );
  StreamSubscription<void>? workloadSubscription;

  void resumePersistedReconciliations() {
    if (ref.read(currentUserProvider) == null) return;
    unawaited(
      ref.read(backgroundUploadServiceProvider).resumePersistedReconciliations().catchError((Object _, StackTrace __) {
        coordinator.signal(EagerBackupTrigger.reconciliationBlocked);
      }),
    );
  }

  Future<void> watchWorkload(String? userId) async {
    await workloadSubscription?.cancel();
    workloadSubscription = userId == null
        ? null
        : backups.watchAllCounts(userId).listen((_) {
            coordinator.signal(EagerBackupTrigger.workloadChanged);
            resumePersistedReconciliations();
          });
    if (userId != null) resumePersistedReconciliations();
  }

  void publishTransport(BackupTransportSnapshot snapshot) {
    publishBackupTransportCursor(
      current: ref.read(backupTransportCursorProvider),
      snapshot: snapshot,
      publish: (cursor) => ref.read(backupTransportCursorProvider.notifier).state = cursor,
    );
    coordinator.setTransport(snapshot);
    if (snapshot.hasWifi) resumePersistedReconciliations();
  }

  final connectivitySubscription = connectivity.snapshotEvents.listen(publishTransport);
  final signalSubscription = ref.read(eagerBackupSignalProvider).events.listen(coordinator.signal);
  final enabledSubscription = Store.watch<bool>(AppSettingsEnum.enableBackup.storeKey)
      .asyncMap((enabled) async {
        final isEnabled = enabled ?? false;
        coordinator.setEnabled(isEnabled);
        if (!isEnabled && !await ref.read(backupDisableBarrierProvider).disable()) coordinator.reportDrainFailed();
      })
      .listen((_) {}, onError: (_, _) => coordinator.reportDrainFailed());
  ref.listen(currentUserProvider.select((user) => user?.id), (_, next) => unawaited(watchWorkload(next)));
  ref.listen(serverReachabilityStateProvider, (_, next) {
    final proofAvailable = next.phase == ReachabilityPhase.online && next.serverAccess?.isCurrent == true;
    coordinator.setServerProofAvailable(proofAvailable);
    if (proofAvailable) resumePersistedReconciliations();
  });

  coordinator
    ..setEnabled(ref.read(appSettingsServiceProvider).getSetting(AppSettingsEnum.enableBackup))
    ..setForeground(true);
  final reachability = ref.read(serverReachabilityStateProvider);
  coordinator.setServerProofAvailable(
    reachability.phase == ReachabilityPhase.online && reachability.serverAccess?.isCurrent == true,
  );
  unawaited(connectivity.initialSnapshot);
  unawaited(watchWorkload(ref.read(currentUserProvider)?.id));
  unawaited(photoObserver.start());
  coordinator.signal(EagerBackupTrigger.startup);

  ref.onDispose(() {
    unawaited(connectivitySubscription.cancel());
    unawaited(signalSubscription.cancel());
    unawaited(enabledSubscription.cancel());
    unawaited(workloadSubscription?.cancel());
    unawaited(photoObserver.dispose());
    unawaited(coordinator.dispose());
  });
  return coordinator;
});
