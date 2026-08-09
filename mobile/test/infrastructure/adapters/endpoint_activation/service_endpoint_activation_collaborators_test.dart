import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/service_endpoint_activation_collaborators.dart';
import 'package:immich_mobile/services/api.service.dart';

void main() {
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
}
