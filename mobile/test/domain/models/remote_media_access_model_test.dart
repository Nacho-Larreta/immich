import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

void main() {
  test('HTTPS proof permits reads while reachability is unknown', () {
    final proof = ConfirmedServerAccess(
      apiEndpoint: Uri.parse('https://photos.test/api'),
      canonicalOrigin: Uri.parse('https://photos.test'),
      schemePolicy: EndpointSchemePolicy.httpsOnly,
      nativeContextGeneration: 17,
      confirmed: true,
      fenced: false,
    );
    final access = mapRemoteMediaAccess(
      ReachabilityState(
        phase: ReachabilityPhase.unknown,
        sessionEpoch: 3,
        probeGeneration: 4,
        confirmedEndpoint: proof.apiEndpoint,
        serverAccess: proof,
      ),
    );

    expect(access.policy, RemoteMediaPolicy.cacheThenNetwork);
    expect(access.expectedContextGeneration, 17);
  });

  for (final policy in [EndpointSchemePolicy.explicitlyApprovedHttp, EndpointSchemePolicy.registeredLocalHttp]) {
    test('${policy.name} proof remains cache-only until online', () {
      final proof = ConfirmedServerAccess(
        apiEndpoint: Uri.parse('http://photos.test/api'),
        canonicalOrigin: Uri.parse('http://photos.test'),
        schemePolicy: policy,
        nativeContextGeneration: 9,
        confirmed: true,
        fenced: false,
      );
      final access = mapRemoteMediaAccess(
        ReachabilityState(
          phase: ReachabilityPhase.unknown,
          sessionEpoch: 1,
          probeGeneration: 1,
          confirmedEndpoint: proof.apiEndpoint,
          serverAccess: proof,
        ),
      );

      expect(access.policy, RemoteMediaPolicy.cacheOnly);
      expect(access.expectedContextGeneration, 9);
    });
  }

  test('fenced or unconfirmed proof cannot authorize a remote read', () {
    for (final proof in [
      ConfirmedServerAccess(
        apiEndpoint: Uri.parse('https://photos.test/api'),
        canonicalOrigin: Uri.parse('https://photos.test'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: 2,
        confirmed: false,
        fenced: false,
      ),
      ConfirmedServerAccess(
        apiEndpoint: Uri.parse('https://photos.test/api'),
        canonicalOrigin: Uri.parse('https://photos.test'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: 2,
        confirmed: true,
        fenced: true,
      ),
    ]) {
      expect(
        mapRemoteMediaAccess(
          ReachabilityState(
            phase: ReachabilityPhase.online,
            sessionEpoch: 1,
            probeGeneration: 1,
            confirmedEndpoint: proof.apiEndpoint,
            serverAccess: proof,
          ),
        ).policy,
        RemoteMediaPolicy.cacheOnly,
      );
    }
  });

  test('cleared or mismatched endpoint cannot reuse stale proof', () {
    final proof = _proof(
      endpoint: Uri.parse('https://photos.example.test/api'),
      policy: EndpointSchemePolicy.httpsOnly,
    );
    final cleared = ReachabilityState(
      phase: ReachabilityPhase.unknown,
      sessionEpoch: 3,
      probeGeneration: 4,
      serverAccess: proof,
    );
    final mismatched = ReachabilityState(
      phase: ReachabilityPhase.unknown,
      sessionEpoch: 3,
      probeGeneration: 4,
      confirmedEndpoint: Uri.parse('https://photos.example.test/other-api'),
      serverAccess: proof,
    );

    expect(mapRemoteMediaAccess(cleared).policy, RemoteMediaPolicy.cacheOnly);
    expect(mapRemoteMediaAccess(mismatched).policy, RemoteMediaPolicy.cacheOnly);
  });

  for (final phase in ReachabilityPhase.values) {
    test('maps ${phase.name} to the expected immutable remote media policy', () {
      final endpoint = Uri.parse('https://photos.example.test/api');
      final proof = phase == ReachabilityPhase.online
          ? ConfirmedServerAccess(
              apiEndpoint: endpoint,
              canonicalOrigin: Uri.parse('https://photos.example.test'),
              schemePolicy: EndpointSchemePolicy.httpsOnly,
              nativeContextGeneration: 5,
              confirmed: true,
              fenced: false,
            )
          : null;
      final state = ReachabilityState(
        phase: phase,
        sessionEpoch: 7,
        probeGeneration: 3,
        confirmedEndpoint: phase == ReachabilityPhase.online ? endpoint : null,
        serverAccess: proof,
      );

      expect(
        mapRemoteMediaAccess(state),
        RemoteMediaAccessSnapshot(
          policy: phase == ReachabilityPhase.online ? RemoteMediaPolicy.cacheThenNetwork : RemoteMediaPolicy.cacheOnly,
          sessionEpoch: 7,
          expectedContextGeneration: proof?.nativeContextGeneration,
        ),
      );
    });
  }

  test('confirmed endpoint remains network-capable during a benign probe', () {
    final proof = ConfirmedServerAccess(
      apiEndpoint: Uri.parse('https://photos.example.test/api'),
      canonicalOrigin: Uri.parse('https://photos.example.test'),
      schemePolicy: EndpointSchemePolicy.httpsOnly,
      nativeContextGeneration: 6,
      confirmed: true,
      fenced: false,
    );
    final state = ReachabilityState(
      phase: ReachabilityPhase.probing,
      sessionEpoch: 7,
      probeGeneration: 4,
      confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
      serverAccess: proof,
    );

    expect(
      mapRemoteMediaAccess(state),
      const RemoteMediaAccessSnapshot(
        policy: RemoteMediaPolicy.cacheThenNetwork,
        sessionEpoch: 7,
        expectedContextGeneration: 6,
      ),
    );
  });

  test('endpoint snapshot owns only its canonical origin and builds stable URLs', () {
    final endpoint = RemoteMediaEndpointSnapshot(Uri.parse('HTTPS://Photos.Example.Test:443/api/'));

    expect(endpoint.owns(Uri.parse('https://photos.example.test/api/assets/1/thumbnail')), isTrue);
    expect(endpoint.owns(Uri.parse('https://other.example.test/api/assets/1/thumbnail')), isFalse);
    expect(
      endpoint.assetOriginal('asset 1', edited: false),
      Uri.parse('https://photos.example.test/api/assets/asset%201/original?edited=false'),
    );
  });
}

ConfirmedServerAccess _proof({required Uri endpoint, required EndpointSchemePolicy policy}) {
  return ConfirmedServerAccess(
    apiEndpoint: endpoint,
    canonicalOrigin: Uri.parse(endpoint.origin),
    schemePolicy: policy,
    nativeContextGeneration: 12,
    confirmed: true,
    fenced: false,
  );
}
