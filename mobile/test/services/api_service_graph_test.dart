import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/infrastructure/repositories/tags_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';

void main() {
  test('repository created before graph swap resolves the newly installed API graph', () async {
    late Uri requestedUri;
    final client = MockClient((request) async {
      requestedUri = request.url;
      return Response('[]', 200, headers: {'content-type': 'application/json'});
    });
    final apiService = ApiService(client: client, initialEndpoint: 'https://old.test/api');
    final repository = TagsApiRepository(apiService);
    final previousClient = apiService.apiClient;

    apiService.installGraph(apiService.prepareGraph('https://new.test/family/api'));
    await repository.getAllTags();

    expect(requestedUri.origin, 'https://new.test');
    expect(requestedUri.path, '/family/api/tags');
    expect(apiService.apiClient, isNot(same(previousClient)));
  });
}
