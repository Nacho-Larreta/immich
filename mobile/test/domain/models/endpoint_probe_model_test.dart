import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

void main() {
  group('EndpointProbeRequest', () {
    test('carries the epoch and generation needed to reject stale completions', () {
      final request = EndpointProbeRequest(
        candidateOrigin: Uri.parse('https://photos.example.test'),
        candidateApiEndpoint: Uri.parse('https://photos.example.test/immich/api'),
        expectedUserId: 'user-1',
        sessionEpoch: 4,
        probeGeneration: 9,
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      );

      expect(request.sessionEpoch, 4);
      expect(request.probeGeneration, 9);
      expect(request.candidateOrigin.path, '');
      expect(request.candidateApiEndpoint.path, '/immich/api');
    });

    test('rejects a candidate that is not an origin', () {
      expect(
        () => EndpointProbeRequest(
          candidateOrigin: Uri.parse('https://photos.example.test/api'),
          candidateApiEndpoint: Uri.parse('https://photos.example.test/api'),
          expectedUserId: 'user-1',
          sessionEpoch: 0,
          probeGeneration: 0,
          schemePolicy: EndpointSchemePolicy.httpsOnly,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('requires an explicit approved exception for local HTTP', () {
      final httpOrigin = Uri.parse('http://192.168.1.10');

      expect(
        () => EndpointProbeRequest(
          candidateOrigin: httpOrigin,
          candidateApiEndpoint: Uri.parse('http://192.168.1.10/api'),
          expectedUserId: 'user-1',
          sessionEpoch: 0,
          probeGeneration: 0,
          schemePolicy: EndpointSchemePolicy.httpsOnly,
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        EndpointProbeRequest(
          candidateOrigin: httpOrigin,
          candidateApiEndpoint: Uri.parse('http://192.168.1.10/api'),
          expectedUserId: 'user-1',
          sessionEpoch: 0,
          probeGeneration: 0,
          schemePolicy: EndpointSchemePolicy.registeredLocalHttp,
        ).candidateOrigin,
        httpOrigin,
      );
    });

    test('rejects non-HTTP endpoint schemes', () {
      expect(
        () => EndpointProbeRequest(
          candidateOrigin: Uri.parse('ftp://photos.example.test'),
          candidateApiEndpoint: Uri.parse('ftp://photos.example.test/api'),
          expectedUserId: 'user-1',
          sessionEpoch: 0,
          probeGeneration: 0,
          schemePolicy: EndpointSchemePolicy.explicitlyApprovedHttp,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects an API endpoint from another security origin', () {
      expect(
        () => EndpointProbeRequest(
          candidateOrigin: Uri.parse('https://photos.example.test'),
          candidateApiEndpoint: Uri.parse('https://other.example.test/api'),
          expectedUserId: 'user-1',
          sessionEpoch: 0,
          probeGeneration: 0,
          schemePolicy: EndpointSchemePolicy.httpsOnly,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('rejects a candidate endpoint whose path does not end in api', () {
      expect(
        () => EndpointProbeRequest(
          candidateOrigin: Uri.parse('https://photos.example.test'),
          candidateApiEndpoint: Uri.parse('https://photos.example.test/immich'),
          expectedUserId: 'user-1',
          sessionEpoch: 0,
          probeGeneration: 0,
          schemePolicy: EndpointSchemePolicy.httpsOnly,
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });

  test('validated result preserves security origin and full API endpoint', () {
    final origin = Uri.parse('https://photos.example.test');
    final apiEndpoint = Uri.parse('https://photos.example.test/immich/api');
    final result = EndpointProbeResult.validated(
      canonicalOrigin: origin,
      apiEndpoint: apiEndpoint,
      userId: 'user-1',
      schemePolicy: EndpointSchemePolicy.httpsOnly,
    );

    expect(
      result,
      ValidatedEndpointProbeResult(
        canonicalOrigin: origin,
        apiEndpoint: apiEndpoint,
        userId: 'user-1',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
    );
  });

  test('rejected result contains only the typed failure', () {
    const result = EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);

    expect(result, const RejectedEndpointProbeResult(OfflineErrorCode.wrongServer));
  });

  test('validated result rejects a non-origin and empty identity', () {
    expect(
      () => EndpointProbeResult.validated(
        canonicalOrigin: Uri.parse('https://photos.example.test/api'),
        apiEndpoint: Uri.parse('https://photos.example.test/api'),
        userId: 'user-1',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => EndpointProbeResult.validated(
        canonicalOrigin: Uri.parse('https://photos.example.test'),
        apiEndpoint: Uri.parse('https://photos.example.test/api'),
        userId: '',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('validated HTTP result requires the approved local policy', () {
    final httpOrigin = Uri.parse('http://192.168.1.10');

    expect(
      () => EndpointProbeResult.validated(
        canonicalOrigin: httpOrigin,
        apiEndpoint: Uri.parse('http://192.168.1.10/api'),
        userId: 'user-1',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
      throwsA(isA<ArgumentError>()),
    );

    final approved = EndpointProbeResult.validated(
      canonicalOrigin: httpOrigin,
      apiEndpoint: Uri.parse('http://192.168.1.10/api'),
      userId: 'user-1',
      schemePolicy: EndpointSchemePolicy.explicitlyApprovedHttp,
    );

    expect((approved as ValidatedEndpointProbeResult).schemePolicy, EndpointSchemePolicy.explicitlyApprovedHttp);
  });

  test('activation receipt preserves approval and validates epoch at runtime', () {
    final endpoint = ValidatedEndpointProbeResult(
      canonicalOrigin: Uri.parse('http://192.168.1.10'),
      apiEndpoint: Uri.parse('http://192.168.1.10/immich/api'),
      userId: 'user-1',
      schemePolicy: EndpointSchemePolicy.explicitlyApprovedHttp,
    );

    final receipt = EndpointActivationReceipt(endpoint: endpoint, sessionEpoch: 0, probeGeneration: 1);
    expect(receipt.confirmedEndpoint, endpoint.apiEndpoint);
    expect(receipt.canonicalOrigin, endpoint.canonicalOrigin);
    expect(receipt.schemePolicy, EndpointSchemePolicy.explicitlyApprovedHttp);
    expect(receipt.probeGeneration, 1);
    expect(
      () => EndpointActivationReceipt(endpoint: endpoint, sessionEpoch: -1, probeGeneration: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => EndpointActivationReceipt(endpoint: endpoint, sessionEpoch: 0, probeGeneration: -1),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('activation request validates epoch and generation at runtime', () {
    final endpoint = ValidatedEndpointProbeResult(
      canonicalOrigin: Uri.parse('https://photos.example.test'),
      apiEndpoint: Uri.parse('https://photos.example.test/api'),
      userId: 'user-1',
      schemePolicy: EndpointSchemePolicy.httpsOnly,
    );

    expect(
      () => EndpointActivationRequest(endpoint: endpoint, sessionEpoch: -1, probeGeneration: 0),
      throwsA(isA<ArgumentError>()),
    );
    expect(
      () => EndpointActivationRequest(endpoint: endpoint, sessionEpoch: 0, probeGeneration: -1),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('validated result rejects an API endpoint from another origin', () {
    expect(
      () => EndpointProbeResult.validated(
        canonicalOrigin: Uri.parse('https://photos.example.test'),
        apiEndpoint: Uri.parse('https://other.example.test/api'),
        userId: 'user-1',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });

  test('validated result requires an API endpoint ending in api', () {
    expect(
      () => EndpointProbeResult.validated(
        canonicalOrigin: Uri.parse('https://photos.example.test'),
        apiEndpoint: Uri.parse('https://photos.example.test/immich'),
        userId: 'user-1',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
      throwsA(isA<ArgumentError>()),
    );
  });
}
