import 'package:drift/drift.dart' hide isNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/service_endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/services/api.service.dart';

void main() {
  late Drift db;

  setUpAll(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  setUp(() async {
    await Store.delete(StoreKey.serverEndpoint);
    await Store.delete(StoreKey.serverEndpointSchemePolicy);
    await Store.delete(StoreKey.authenticatedSessionReady);
  });

  tearDownAll(() => db.close());

  test('API graph purge installs a request-safe empty graph', () async {
    final client = Client();
    addTearDown(client.close);
    final apiService = ApiService(client: client, initialEndpoint: 'https://photos.example.test/api');
    final graph = ApiServiceEndpointGraphAdapter(apiService);

    expect(graph.currentEndpoint, Uri.parse('https://photos.example.test/api'));
    await graph.purge();

    expect(graph.currentEndpoint, isNull);
    expect(apiService.apiClient.basePath, isEmpty);
  });

  test('endpoint persistence keeps readiness restrictive until an authenticated commit', () async {
    const store = StoreConfirmedEndpointAdapter();

    await store.write(
      ConfirmedServerEndpoint(
        apiEndpoint: Uri.parse('http://photos.test/api'),
        schemePolicy: EndpointSchemePolicy.explicitlyApprovedHttp,
        authenticatedSessionReady: false,
      ),
    );

    expect(Store.tryGet(StoreKey.authenticatedSessionReady), isFalse);
    expect(Store.tryGet(StoreKey.serverEndpointSchemePolicy), EndpointSchemePolicy.explicitlyApprovedHttp.name);
    expect(Store.tryGet(StoreKey.serverEndpoint), 'http://photos.test/api');
  });

  test('authenticated endpoint commit publishes readiness only after a compatible pair', () async {
    const store = StoreConfirmedEndpointAdapter();

    await store.write(
      ConfirmedServerEndpoint(
        apiEndpoint: Uri.parse('https://photos.test/api'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
    );

    final restored = store.read();
    expect(restored?.apiEndpoint, Uri.parse('https://photos.test/api'));
    expect(restored?.schemePolicy, EndpointSchemePolicy.httpsOnly);
    expect(restored?.authenticatedSessionReady, isTrue);
  });

  test('stored incompatible endpoint and policy are never exposed as confirmed', () async {
    await Store.put(StoreKey.authenticatedSessionReady, true);
    await Store.put(StoreKey.serverEndpoint, 'http://photos.test/api');
    await Store.put(StoreKey.serverEndpointSchemePolicy, EndpointSchemePolicy.httpsOnly.name);

    expect(const StoreConfirmedEndpointAdapter().read(), isNull);
  });
}
