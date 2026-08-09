import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
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
  Uri? read() {
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    return endpoint == null || endpoint.isEmpty ? null : Uri.parse(endpoint);
  }

  @override
  Future<void> write(Uri? endpoint) async {
    if (endpoint == null || endpoint.toString().isEmpty) {
      await Store.delete(StoreKey.serverEndpoint);
      return;
    }
    await Store.put(StoreKey.serverEndpoint, endpoint.toString());
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
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    final endpointUri = endpoint == null || endpoint.isEmpty ? null : Uri.parse(endpoint);
    return NativeRequestContext(
      canonicalOrigin: endpointUri == null ? null : Uri.parse(endpointUri.origin),
      accessToken: Store.tryGet(StoreKey.accessToken),
      customHeaders: ApiService.getRequestHeaders(),
    );
  }

  @override
  Future<void> replace(NativeRequestContext context) {
    return NetworkRepository.replaceRequestContext(
      headers: context.customHeaders,
      canonicalOrigin: context.canonicalOrigin,
      token: context.accessToken,
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
