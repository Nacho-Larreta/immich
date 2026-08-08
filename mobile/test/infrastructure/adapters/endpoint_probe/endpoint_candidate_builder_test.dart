import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_candidate_builder.dart';

void main() {
  const builder = EndpointCandidateBuilder();

  group('EndpointCandidateBuilder', () {
    test('prefers the registered local endpoint and canonicalizes endpoint identity', () {
      final candidates = builder.build(
        approvedEndpoints: const ['https://PHOTOS.EXAMPLE.TEST:443/immich/api/', 'https://backup.example.test/api'],
        registeredLocalEndpoint: 'http://NAS.LOCAL:80/immich/api/',
        currentWifiName: 'Home',
        preferredWifiName: 'Home',
        expectedUserId: 'user-1',
        sessionEpoch: 4,
        probeGeneration: 9,
      );

      expect(candidates.map((candidate) => candidate.candidateOrigin), [
        Uri.parse('http://nas.local'),
        Uri.parse('https://photos.example.test'),
        Uri.parse('https://backup.example.test'),
      ]);
      expect(candidates.first.schemePolicy, EndpointSchemePolicy.approvedLocalHttp);
      expect(candidates.first.expectedUserId, 'user-1');
      expect(candidates.first.sessionEpoch, 4);
      expect(candidates.first.probeGeneration, 9);
      expect(candidates.map((candidate) => candidate.candidateApiEndpoint), [
        Uri.parse('http://nas.local/immich/api'),
        Uri.parse('https://photos.example.test/immich/api'),
        Uri.parse('https://backup.example.test/api'),
      ]);
      expect(candidates.skip(1).map((candidate) => candidate.schemePolicy), {EndpointSchemePolicy.httpsOnly});
    });

    test('never derives an HTTP exception away from the registered local endpoint and preferred WiFi', () {
      final candidates = builder.build(
        approvedEndpoints: const ['http://external.example.test/api', 'https://external.example.test/api'],
        registeredLocalEndpoint: 'http://nas.local:2283/api',
        currentWifiName: 'CoffeeShop',
        preferredWifiName: 'Home',
        expectedUserId: 'user-1',
        sessionEpoch: 0,
        probeGeneration: 0,
      );

      expect(candidates, hasLength(1));
      expect(candidates.single.candidateOrigin, Uri.parse('https://external.example.test'));
      expect(candidates.single.candidateApiEndpoint, Uri.parse('https://external.example.test/api'));
      expect(candidates.single.schemePolicy, EndpointSchemePolicy.httpsOnly);
    });

    test('deduplicates exact API endpoints while preserving same-origin subpaths and order', () {
      final candidates = builder.build(
        approvedEndpoints: const [
          'https://photos.example.test/familia/api',
          'https://PHOTOS.EXAMPLE.TEST:443/familia/api/',
          'https://photos.example.test/archivo/api',
          'https://second.example.test/api',
        ],
        registeredLocalEndpoint: null,
        currentWifiName: null,
        preferredWifiName: null,
        expectedUserId: 'user-1',
        sessionEpoch: 1,
        probeGeneration: 2,
      );

      expect(candidates.map((candidate) => candidate.candidateApiEndpoint), [
        Uri.parse('https://photos.example.test/familia/api'),
        Uri.parse('https://photos.example.test/archivo/api'),
        Uri.parse('https://second.example.test/api'),
      ]);
    });

    test('ignores invalid API paths and non-HTTP endpoint schemes', () {
      final candidates = builder.build(
        approvedEndpoints: const [
          'https://photos.example.test/immich',
          'https://photos.example.test/api?tenant=family',
          'ftp://photos.example.test/api',
          'https://photos.example.test/family/api',
        ],
        registeredLocalEndpoint: 'http://nas.local:2283/immich',
        currentWifiName: 'Home',
        preferredWifiName: 'Home',
        expectedUserId: 'user-1',
        sessionEpoch: 1,
        probeGeneration: 2,
      );

      expect(candidates.map((candidate) => candidate.candidateApiEndpoint), [
        Uri.parse('https://photos.example.test/family/api'),
      ]);
    });

    test('allows only the exact registered HTTP API endpoint on its preferred WiFi', () {
      final candidates = builder.build(
        approvedEndpoints: const [
          'http://nas.local:2283/familia/api',
          'http://nas.local:2283/archivo/api',
          'https://remote.example.test/api',
        ],
        registeredLocalEndpoint: 'http://nas.local:2283/familia/api',
        currentWifiName: 'Home',
        preferredWifiName: 'Home',
        expectedUserId: 'user-1',
        sessionEpoch: 1,
        probeGeneration: 2,
      );

      expect(candidates.map((candidate) => candidate.candidateApiEndpoint), [
        Uri.parse('http://nas.local:2283/familia/api'),
        Uri.parse('https://remote.example.test/api'),
      ]);
      expect(candidates.first.schemePolicy, EndpointSchemePolicy.approvedLocalHttp);
    });
  });
}
