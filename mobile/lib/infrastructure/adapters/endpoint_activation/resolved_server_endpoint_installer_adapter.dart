import 'package:immich_mobile/domain/interfaces/resolved_server_endpoint_installer.interface.dart';
import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';

final class ResolvedServerEndpointInstallerAdapter implements ResolvedServerEndpointInstallerPort {
  const ResolvedServerEndpointInstallerAdapter({
    required SessionMutationMutex mutex,
    required EndpointApiGraphPort apiGraph,
    required NativeRequestContextPort nativeContext,
    required ConfirmedEndpointStorePort endpointStore,
    required Future<void> Function() installDeviceInfoHeaders,
  }) : _mutex = mutex,
       _apiGraph = apiGraph,
       _nativeContext = nativeContext,
       _endpointStore = endpointStore,
       _installDeviceInfoHeaders = installDeviceInfoHeaders;

  final SessionMutationMutex _mutex;
  final EndpointApiGraphPort _apiGraph;
  final NativeRequestContextPort _nativeContext;
  final ConfirmedEndpointStorePort _endpointStore;
  final Future<void> Function() _installDeviceInfoHeaders;

  @override
  Future<void> installResolvedServerEndpoint(DiscoveredServerEndpoint endpoint) {
    return _mutex.protect(() => _install(endpoint));
  }

  Future<void> _install(DiscoveredServerEndpoint endpoint) async {
    final schemePolicy = endpoint.canonicalOrigin.scheme == 'https'
        ? EndpointSchemePolicy.httpsOnly
        : EndpointSchemePolicy.explicitlyApprovedHttp;
    final previousEndpoint = _apiGraph.currentEndpoint;
    final previousStoredEndpoint = _endpointStore.read();
    final preparedGraph = await _apiGraph.prepare(endpoint.apiEndpoint);
    final previousGraph = await _apiGraph.prepare(previousEndpoint ?? Uri());
    _nativeContext.block();
    _apiGraph.block();
    try {
      await _nativeContext.replace(
        NativeRequestContext(
          apiEndpoint: endpoint.apiEndpoint,
          canonicalOrigin: endpoint.canonicalOrigin,
          accessToken: null,
          schemePolicy: schemePolicy,
          customHeaders: const {},
        ),
      );
      await _apiGraph.install(preparedGraph);
      await _endpointStore.write(
        ConfirmedServerEndpoint(
          apiEndpoint: endpoint.apiEndpoint,
          schemePolicy: schemePolicy,
          authenticatedSessionReady: false,
        ),
      );
      await _installDeviceInfoHeaders();
    } catch (installationError, installationStackTrace) {
      final rollbackError = await _rollback(graph: previousGraph, storedEndpoint: previousStoredEndpoint);
      if (rollbackError != null) {
        throw ServerEndpointInstallationException(installationError: installationError, rollbackError: rollbackError);
      }
      Error.throwWithStackTrace(installationError, installationStackTrace);
    }
  }

  Future<Object?> _rollback({required PreparedApiGraph graph, required ConfirmedServerEndpoint? storedEndpoint}) async {
    Object? firstError;

    void recordError(Object error) {
      firstError ??= error;
    }

    void fence() {
      for (final block in [_nativeContext.block, _apiGraph.block]) {
        try {
          block();
        } catch (error) {
          recordError(error);
        }
      }
    }

    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error) {
        recordError(error);
      }
    }

    fence();
    await attempt(() => _apiGraph.install(graph));
    await attempt(() => _endpointStore.write(storedEndpoint));
    await attempt(_nativeContext.purge);
    if (firstError == null) {
      try {
        _nativeContext.publishCleared();
      } catch (error) {
        recordError(error);
      }
    }
    if (firstError != null) {
      fence();
    }
    return firstError;
  }
}

final class ServerEndpointInstallationException implements Exception {
  const ServerEndpointInstallationException({required this.installationError, required this.rollbackError});

  final Object installationError;
  final Object rollbackError;

  @override
  String toString() {
    return 'ServerEndpointInstallationException: installation failed ($installationError); '
        'rollback failed ($rollbackError)';
  }
}
