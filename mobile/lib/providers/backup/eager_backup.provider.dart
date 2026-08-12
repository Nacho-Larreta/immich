import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/eager_backup_coordinator.dart';
import 'package:immich_mobile/domain/services/eager_backup_workload_subscription.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/eager_backup_operations_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/drift_eager_backup_workload_monitor_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/logging_eager_backup_diagnostics_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/photo_manager_change_observer_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/backup_execution.provider.dart';
import 'package:immich_mobile/providers/backup/backup_enablement.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup_signal.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('EagerBackup');

final eagerBackupDiagnosticsProvider = Provider<EagerBackupDiagnosticsPort>(
  (_) => LoggingEagerBackupDiagnosticsAdapter(_log),
);

final eagerBackupUserIdProvider = Provider<String?>((ref) {
  return ref.watch(currentUserProvider.select((user) => user?.id));
});

final eagerBackupWorkloadMonitorProvider = Provider<EagerBackupWorkloadMonitorPort>(
  (ref) => DriftEagerBackupWorkloadMonitorAdapter(ref.watch(backupRepositoryProvider)),
);

final eagerBackupOperationsProvider = Provider<EagerBackupOperationsPort>((ref) {
  return EagerBackupOperationsAdapter(
    readUserId: () => ref.read(eagerBackupUserIdProvider),
    backups: ref.read(backupRepositoryProvider),
    synchronization: ref.read(backgroundSyncProvider),
    uploads: ref.read(foregroundUploadServiceProvider),
    arbiter: ref.read(backupExecutionArbiterProvider),
    bindings: ref.read(backupRunBindingSourceProvider),
  );
});

final eagerBackupPhotoObserverFactoryProvider = Provider<EagerBackupPhotoObserverPort Function(void Function())>(
  (_) =>
      (onChanged) => PhotoManagerChangeObserverAdapter(onChanged: onChanged),
);

final eagerBackupResumeReconciliationsProvider = Provider<Future<void> Function()>((ref) {
  return ref.read(backgroundUploadServiceProvider).resumePersistedReconciliations;
});

final eagerBackupEnabledProvider = Provider<bool>(
  (ref) => ref.read(appSettingsServiceProvider).getSetting(AppSettingsEnum.enableBackup),
);

final eagerBackupEnabledChangesProvider = Provider<Stream<bool?>>(
  (_) => Store.watch<bool>(AppSettingsEnum.enableBackup.storeKey),
);

final eagerBackupStateProvider = StreamProvider<EagerBackupState>((ref) async* {
  final coordinator = ref.watch(eagerBackupCoordinatorProvider);
  yield coordinator.state;
  yield* coordinator.states;
});

final eagerBackupStartupProvider = Provider<void>((ref) {
  ref.read(eagerBackupCoordinatorProvider);
  ref.read(backupEnablementControllerProvider);
});

final eagerBackupCoordinatorProvider = Provider<EagerBackupCoordinator>((ref) {
  final diagnostics = FailSafeEagerBackupDiagnostics(ref.read(eagerBackupDiagnosticsProvider));
  diagnostics.report(const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.bootstrapCreated));
  final coordinator = EagerBackupCoordinator(
    operations: ref.read(eagerBackupOperationsProvider),
    diagnostics: diagnostics,
  );
  final connectivity = ref.read(nativeConnectivityMonitorProvider) as ConnectivitySnapshotMonitorPort;
  final photoObserver = ref.read(eagerBackupPhotoObserverFactoryProvider)(
    () => coordinator.signal(EagerBackupTrigger.photoLibraryChanged),
  );

  void resumePersistedReconciliations() {
    if (ref.read(eagerBackupUserIdProvider) == null) return;
    unawaited(
      ref.read(eagerBackupResumeReconciliationsProvider)().catchError((Object _, StackTrace __) {
        coordinator.signal(EagerBackupTrigger.reconciliationBlocked);
      }),
    );
  }

  final workloadSubscription = EagerBackupWorkloadSubscription(
    workloads: ref.read(eagerBackupWorkloadMonitorProvider),
    diagnostics: diagnostics,
    onWorkload: (_) {
      coordinator.signal(EagerBackupTrigger.workloadChanged);
      resumePersistedReconciliations();
    },
  );

  Future<void> watchWorkload(String? userId) async {
    final isCurrent = await workloadSubscription.replace(userId);
    if (isCurrent && userId != null) resumePersistedReconciliations();
  }

  void publishTransport(BackupTransportSnapshot snapshot) {
    diagnostics.report(
      EagerBackupDiagnosticEvent(
        EagerBackupDiagnosticCode.connectivitySnapshot,
        available: snapshot.available,
        wifi: snapshot.hasWifi,
      ),
    );
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
  final enabledSubscription = ref
      .read(eagerBackupEnabledChangesProvider)
      .asyncMap((enabled) async {
        final isEnabled = enabled ?? false;
        coordinator.setEnabled(isEnabled);
      })
      .listen((_) {}, onError: (_, _) => coordinator.reportDrainFailed());
  ref.listen(eagerBackupUserIdProvider, (_, next) => unawaited(watchWorkload(next)));
  ref.listen(serverReachabilityStateProvider, (_, next) {
    final proofAvailable = next.phase == ReachabilityPhase.online && next.serverAccess?.isCurrent == true;
    coordinator.setServerProofAvailable(proofAvailable);
    if (proofAvailable) resumePersistedReconciliations();
  });

  final enabled = ref.read(eagerBackupEnabledProvider);
  final userId = ref.read(eagerBackupUserIdProvider);
  diagnostics.report(
    EagerBackupDiagnosticEvent(
      EagerBackupDiagnosticCode.bootstrapConfiguration,
      enabled: enabled,
      userPresent: userId != null,
    ),
  );
  coordinator
    ..setEnabled(enabled)
    ..setForeground(true);
  final reachability = ref.read(serverReachabilityStateProvider);
  coordinator.setServerProofAvailable(
    reachability.phase == ReachabilityPhase.online && reachability.serverAccess?.isCurrent == true,
  );
  unawaited(
    connectivity.initialSnapshot.catchError((Object _, StackTrace __) {
      diagnostics.report(const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.connectivityInitializationFailed));
      return const BackupTransportSnapshot(available: false, capabilities: {});
    }),
  );
  unawaited(watchWorkload(userId));
  unawaited(
    photoObserver.start().then(
      (_) => diagnostics.report(const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.photoObserverStarted)),
      onError: (Object _, StackTrace __) =>
          diagnostics.report(const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.photoObserverStartFailed)),
    ),
  );
  coordinator.signal(EagerBackupTrigger.startup);

  ref.onDispose(() {
    unawaited(connectivitySubscription.cancel());
    unawaited(signalSubscription.cancel());
    unawaited(enabledSubscription.cancel());
    unawaited(workloadSubscription.dispose());
    unawaited(photoObserver.dispose());
    unawaited(coordinator.dispose());
  });
  return coordinator;
});
