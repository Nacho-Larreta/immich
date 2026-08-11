import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/widget.service.dart';

final class ApiServicePreparedGraph implements PreparedApiGraph {
  const ApiServicePreparedGraph(this.graph);

  final ApiServiceGraph graph;
}

final class ApiServiceEndpointGraphAdapter implements EndpointApiGraphPort, AuthApiGraphPort {
  const ApiServiceEndpointGraphAdapter(this._apiService);

  final ApiService _apiService;

  @override
  Uri? get currentEndpoint {
    final basePath = _apiService.apiClient.basePath;
    return basePath.isEmpty ? null : Uri.parse(basePath);
  }

  @override
  void block() {
    _apiService.installGraph(_apiService.prepareGraph(''));
  }

  @override
  Future<PreparedApiGraph> prepare(Uri apiEndpoint) async {
    return ApiServicePreparedGraph(_apiService.prepareGraph(apiEndpoint.toString()));
  }

  @override
  Future<void> install(PreparedApiGraph graph) async {
    if (graph is! ApiServicePreparedGraph) {
      throw ArgumentError.value(graph, 'graph', 'Expected an ApiServicePreparedGraph');
    }
    _apiService.installGraph(graph.graph);
  }

  @override
  Future<void> purge() async {
    block();
    if (currentEndpoint != null) {
      throw StateError('API graph still has an active endpoint after purge');
    }
  }
}

final class StoreConfirmedEndpointAdapter implements ConfirmedEndpointStorePort {
  const StoreConfirmedEndpointAdapter();

  @override
  ConfirmedServerEndpoint? read() {
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    if (endpoint == null || endpoint.isEmpty) return null;
    final apiEndpoint = Uri.tryParse(endpoint);
    if (apiEndpoint == null) return null;
    final storedPolicy = parseEndpointSchemePolicy(Store.tryGet(StoreKey.serverEndpointSchemePolicy));
    final policy = storedPolicy ?? (apiEndpoint.scheme == 'https' ? EndpointSchemePolicy.httpsOnly : null);
    if (policy == null) return null;
    try {
      return ConfirmedServerEndpoint(
        apiEndpoint: apiEndpoint,
        schemePolicy: policy,
        authenticatedSessionReady: Store.tryGet(StoreKey.authenticatedSessionReady) == true,
      );
    } on ArgumentError {
      return null;
    }
  }

  @override
  Future<void> write(ConfirmedServerEndpoint? endpoint) async {
    await Store.put(StoreKey.authenticatedSessionReady, false);
    if (endpoint == null) {
      await Future.wait([Store.delete(StoreKey.serverEndpoint), Store.delete(StoreKey.serverEndpointSchemePolicy)]);
      return;
    }
    await Store.put(StoreKey.serverEndpointSchemePolicy, endpoint.schemePolicy.name);
    await Store.put(StoreKey.serverEndpoint, endpoint.apiEndpoint.toString());
    if (endpoint.authenticatedSessionReady) {
      await Store.put(StoreKey.authenticatedSessionReady, true);
    }
  }
}

final class NetworkNativeRequestContextAdapter implements NativeRequestContextPort {
  const NetworkNativeRequestContextAdapter();

  @override
  void block() {
    NetworkRepository.blockRequests();
  }

  @override
  NativeRequestContext snapshot() {
    final evidence = NetworkRepository.serverAccessEvidence;
    final hasConfirmedContext = evidence.confirmed && !evidence.fenced && evidence.apiEndpoint != null;
    return NativeRequestContext(
      apiEndpoint: hasConfirmedContext ? evidence.apiEndpoint : null,
      canonicalOrigin: hasConfirmedContext ? evidence.canonicalOrigin : null,
      accessToken: hasConfirmedContext ? Store.tryGet(StoreKey.accessToken) : null,
      schemePolicy: hasConfirmedContext ? evidence.schemePolicy : null,
      sessionEpoch: evidence.sessionEpoch,
      customHeaders: hasConfirmedContext ? ApiService.getRequestHeaders() : const {},
    );
  }

  @override
  Future<void> replace(NativeRequestContext context) {
    return NetworkRepository.replaceRequestContext(
      headers: context.customHeaders,
      apiEndpoint: context.apiEndpoint,
      canonicalOrigin: context.canonicalOrigin,
      token: context.accessToken,
      schemePolicy: context.schemePolicy,
      sessionEpoch: context.sessionEpoch,
    );
  }

  @override
  Future<void> purge() {
    return NetworkRepository.purgeRequestContext();
  }

  @override
  void publishCleared() {
    NetworkRepository.publishClearedContext();
  }
}

final class WidgetServiceCredentialsAdapter implements WidgetCredentialsPort {
  const WidgetServiceCredentialsAdapter(this._widgetService);

  final WidgetService _widgetService;

  @override
  Future<WidgetCredentials> snapshot() async {
    final credentials = await _widgetService.readCredentials();
    final endpoint = credentials.serverURL;
    return WidgetCredentials(
      apiEndpoint: endpoint == null || endpoint.isEmpty ? null : Uri.parse(endpoint),
      accessToken: credentials.sessionKey,
      customHeaders: credentials.customHeaders,
    );
  }

  @override
  Future<void> write(WidgetCredentials credentials) async {
    await _widgetService.writeCredentialsAndRefresh(
      credentials.apiEndpoint?.toString() ?? '',
      credentials.accessToken ?? '',
      credentials.customHeaders,
    );
  }

  @override
  Future<void> clear() async {
    await _widgetService.clearCredentialsAndRefresh();
  }
}
