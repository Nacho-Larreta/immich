import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_activation.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe_cycle.interface.dart';
import 'package:immich_mobile/domain/interfaces/reachability_scheduler.interface.dart';
import 'package:immich_mobile/domain/interfaces/reachability_state_publisher.interface.dart';
import 'package:immich_mobile/domain/interfaces/reconciliation.interface.dart';
import 'package:immich_mobile/domain/interfaces/request_context_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/server_reachability_coordinator.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/connectivity/native_connectivity_monitor_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/connectivity/publishing_connectivity_monitor_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/current_session_activation_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/registered_local_http_lease_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/service_endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/current_session_endpoint_probe_cycle_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/reachability/reachability_state_publisher_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/reachability/timer_reachability_scheduler.dart';
import 'package:immich_mobile/infrastructure/adapters/reconciliation/server_reconciliation_adapter.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/session_mutation.provider.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/repositories/auth.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/network.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:logging/logging.dart';

final _log = Logger('ServerReachabilityProvider');

final sessionEpochControllerProvider = Provider<SessionEpochController>((_) => SessionEpochController());

final serverReachabilityStateProvider = StateProvider<ReachabilityState>((ref) {
  final identity = ref.read(sessionEpochControllerProvider).current;
  return ReachabilityState(
    phase: ReachabilityPhase.unknown,
    sessionEpoch: identity.sessionEpoch,
    probeGeneration: identity.probeGeneration,
  );
});

final transportAvailabilityProvider = StateProvider<TransportAvailability>((_) => TransportAvailability.unknown);

final reachabilitySchedulerProvider = Provider<ReachabilitySchedulerPort>((_) => const TimerReachabilityScheduler());

final reachabilityStatePublisherProvider = Provider<ReachabilityStatePublisherPort>((ref) {
  final state = ref.read(serverReachabilityStateProvider.notifier);
  return ReachabilityStatePublisherAdapter((value) {
    if (state.mounted) {
      state.state = value;
    }
  });
});

final nativeConnectivityMonitorProvider = Provider<ConnectivityMonitorPort>((ref) {
  return NativeConnectivityMonitorAdapter(api: PigeonConnectivityHostApi(api: ref.read(connectivityApiProvider)));
});

final connectivityMonitorProvider = Provider<ConnectivityMonitorPort>((ref) {
  final availability = ref.read(transportAvailabilityProvider.notifier);
  return PublishingConnectivityMonitorAdapter(
    delegate: ref.read(nativeConnectivityMonitorProvider),
    publish: (value) => availability.state = value,
  );
});

final endpointProbeCycleProvider = Provider<EndpointProbeCyclePort>((ref) {
  final authRepository = ref.read(authRepositoryProvider);
  final networkService = ref.read(networkServiceProvider);
  return CurrentSessionEndpointProbeCycleAdapter(
    transport: ref.read(probeHttpTransportProvider),
    readSnapshot: () async {
      final switchingEnabled = authRepository.getEndpointSwitchingFeature();
      final currentWifiName = switchingEnabled ? await networkService.getWifiName() : null;
      final currentEndpoint = Store.tryGet(StoreKey.serverEndpoint);
      final currentEndpointUri = currentEndpoint == null ? null : Uri.tryParse(currentEndpoint);
      final currentEndpointPolicy =
          parseEndpointSchemePolicy(Store.tryGet(StoreKey.serverEndpointSchemePolicy)) ??
          (currentEndpointUri?.scheme == 'https' ? EndpointSchemePolicy.httpsOnly : null);
      final externalEndpoints = switchingEnabled
          ? authRepository.getExternalEndpointList().map((endpoint) => endpoint.url)
          : const <String>[];
      final user = Store.tryGet(StoreKey.currentUser);
      return EndpointProbeCycleSnapshot(
        currentEndpoint: currentEndpoint,
        currentEndpointPolicy: currentEndpointPolicy,
        externalEndpoints: externalEndpoints,
        registeredLocalEndpoint: switchingEnabled ? authRepository.getLocalEndpoint() : null,
        currentWifiName: currentWifiName,
        preferredWifiName: switchingEnabled ? authRepository.getPreferredWifiName() : null,
        expectedUserId: user?.id ?? '',
        accessToken: Store.tryGet(StoreKey.accessToken) ?? '',
        customHeaders: ApiService.getRequestHeaders(),
      );
    },
  );
});

final endpointActivationProvider = Provider<EndpointActivationPort>((ref) {
  return EndpointActivationAdapter(
    mutex: ref.read(sessionMutationMutexProvider),
    session: CurrentSessionActivationAdapter(ref.read(sessionEpochControllerProvider)),
    apiGraph: ApiServiceEndpointGraphAdapter(ref.read(apiServiceProvider)),
    nativeContext: const NetworkNativeRequestContextAdapter(),
    requestContextLease: ref.read(requestContextLeaseProvider),
    endpointStore: const StoreConfirmedEndpointAdapter(),
    widgetCredentials: WidgetServiceCredentialsAdapter(ref.read(widgetServiceProvider)),
  );
});

final requestContextLeaseProvider = Provider<RequestContextLeasePort>((_) {
  return RegisteredLocalHttpLeaseAdapter(
    readActivePolicy: () => NetworkRepository.activeEndpointSchemePolicy,
    blockRequests: NetworkRepository.blockRequests,
    purgeRequestContext: NetworkRepository.purgeRequestContext,
  );
});

final reconciliationProvider = Provider<ReconciliationPort>((ref) {
  final backgroundSync = ref.read(backgroundSyncProvider);
  final websocket = ref.read(websocketProvider.notifier);
  final backup = ref.read(driftBackupProvider.notifier);
  final settings = ref.read(appSettingsServiceProvider);
  return ServerReconciliationAdapter(
    epochs: ref.read(sessionEpochControllerProvider),
    readSnapshot: () {
      final user = Store.tryGet(StoreKey.currentUser);
      return ReconciliationSnapshot(
        syncAlbums: settings.getSetting(AppSettingsEnum.syncAlbums),
        backupEnabled: settings.getSetting(AppSettingsEnum.enableBackup),
        userId: user?.id,
      );
    },
    disconnectWebsocket: websocket.disconnect,
    connectWebsocket: websocket.connect,
    syncRemote: backgroundSync.syncRemote,
    hashAssets: backgroundSync.hashAssets,
    syncLinkedAlbums: backgroundSync.syncLinkedAlbum,
    startBackup: backup.startForegroundBackup,
    stopBackup: backup.stopForegroundBackup,
    cancelRemoteWork: backgroundSync.cancel,
    cancelLocalWork: backgroundSync.cancelLocal,
  );
});

final serverReachabilityCoordinatorProvider = Provider<ServerReachabilityCoordinator>((ref) {
  final coordinator = ServerReachabilityCoordinator(
    epochs: ref.read(sessionEpochControllerProvider),
    connectivity: ref.read(connectivityMonitorProvider),
    probeCycles: ref.read(endpointProbeCycleProvider),
    activations: ref.read(endpointActivationProvider),
    reconciliations: ref.read(reconciliationProvider),
    statePublisher: ref.read(reachabilityStatePublisherProvider),
    scheduler: ref.read(reachabilitySchedulerProvider),
    requestContextLease: ref.read(requestContextLeaseProvider),
  );
  ref.onDispose(() => unawaited(coordinator.dispose()));
  unawaited(
    Future<void>.microtask(coordinator.start).catchError((Object error, StackTrace stackTrace) {
      _log.severe('Unable to start server reachability coordination', error, stackTrace);
    }),
  );
  return coordinator;
});
