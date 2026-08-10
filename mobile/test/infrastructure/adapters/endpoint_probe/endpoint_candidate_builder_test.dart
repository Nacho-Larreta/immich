import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_candidate_builder.dart';

void main() {
  const builder = EndpointCandidateBuilder();

  group('EndpointCandidateBuilder', () {
    test('prefers the registered local endpoint and canonicalizes endpoint identity', () {
      final candidates = builder.build(
        currentEndpoint: 'https://PHOTOS.EXAMPLE.TEST:443/immich/api/',
        currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
        externalEndpoints: const ['https://backup.example.test/api'],
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
      expect(candidates.first.schemePolicy, EndpointSchemePolicy.registeredLocalHttp);
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
        currentEndpoint: 'https://external.example.test/api',
        currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
        externalEndpoints: const ['http://external.example.test/api'],
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
        currentEndpoint: 'https://photos.example.test/familia/api',
        currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
        externalEndpoints: const [
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
        currentEndpoint: 'https://photos.example.test/family/api',
        currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
        externalEndpoints: const [
          'https://photos.example.test/immich',
          'https://photos.example.test/api?tenant=family',
          'ftp://photos.example.test/api',
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
        currentEndpoint: 'https://remote.example.test/api',
        currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
        externalEndpoints: const ['http://nas.local:2283/familia/api', 'http://nas.local:2283/archivo/api'],
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
      expect(candidates.first.schemePolicy, EndpointSchemePolicy.registeredLocalHttp);
    });

    test('probes the explicitly selected HTTP endpoint even when switching is disabled', () {
      final candidates = builder.build(
        currentEndpoint: 'http://nas.local:2283/api',
        currentEndpointPolicy: EndpointSchemePolicy.explicitlyApprovedHttp,
        externalEndpoints: const [],
        registeredLocalEndpoint: null,
        currentWifiName: null,
        preferredWifiName: null,
        expectedUserId: 'user-1',
        sessionEpoch: 1,
        probeGeneration: 2,
      );

      expect(candidates.single.candidateApiEndpoint, Uri.parse('http://nas.local:2283/api'));
      expect(candidates.single.schemePolicy, EndpointSchemePolicy.explicitlyApprovedHttp);
    });

    test('does not probe a current HTTP endpoint without persisted approval', () {
      final candidates = builder.build(
        currentEndpoint: 'http://nas.local:2283/api',
        currentEndpointPolicy: null,
        externalEndpoints: const [],
        registeredLocalEndpoint: null,
        currentWifiName: null,
        preferredWifiName: null,
        expectedUserId: 'user-1',
        sessionEpoch: 1,
        probeGeneration: 2,
      );

      expect(candidates, isEmpty);
    });

    test('keeps the current HTTPS endpoint on the strict HTTPS policy', () {
      final candidates = builder.build(
        currentEndpoint: 'https://photos.example.test/api',
        currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
        externalEndpoints: const [],
        registeredLocalEndpoint: null,
        currentWifiName: null,
        preferredWifiName: null,
        expectedUserId: 'user-1',
        sessionEpoch: 1,
        probeGeneration: 2,
      );

      expect(candidates.single.schemePolicy, EndpointSchemePolicy.httpsOnly);
    });
  });
}
