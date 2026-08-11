import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

void main() {
  for (final phase in ReachabilityPhase.values) {
    test('maps ${phase.name} to the expected immutable remote media policy', () {
      final state = ReachabilityState(
        phase: phase,
        sessionEpoch: 7,
        probeGeneration: 3,
        confirmedEndpoint: phase == ReachabilityPhase.online ? Uri.parse('https://photos.example.test/api') : null,
      );

      expect(
        mapRemoteMediaAccess(state),
        RemoteMediaAccessSnapshot(
          policy: phase == ReachabilityPhase.online ? RemoteMediaPolicy.cacheThenNetwork : RemoteMediaPolicy.cacheOnly,
          sessionEpoch: 7,
        ),
      );
    });
  }

  test('confirmed endpoint remains network-capable during a benign probe', () {
    final state = ReachabilityState(
      phase: ReachabilityPhase.probing,
      sessionEpoch: 7,
      probeGeneration: 4,
      confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
    );

    expect(
      mapRemoteMediaAccess(state),
      const RemoteMediaAccessSnapshot(policy: RemoteMediaPolicy.cacheThenNetwork, sessionEpoch: 7),
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
