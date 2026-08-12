import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/background_sync/background_task_context_source_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

void main() {
  test('headless source accepts stable native epoch without a process-local controller epoch', () {
    final source = NativeBackgroundTaskContextSourceAdapter(
      readEvidence: () => _evidence(),
      readAuthenticatedSession: _authentication,
    );

    final binding = source.capture();

    expect(binding?.sessionEpoch, 7);
    expect(binding?.nativeContextGeneration, 9);
    expect(binding?.apiEndpoint, Uri.parse('https://photos.example/api'));
  });

  test('headless source rejects unconfirmed, fenced, unauthenticated, incomplete, and torn evidence', () {
    for (final evidence in [
      _evidence(confirmed: false),
      _evidence(fenced: true),
      _evidence(origin: null),
      _evidence(policy: null),
    ]) {
      final source = NativeBackgroundTaskContextSourceAdapter(
        readEvidence: () => evidence,
        readAuthenticatedSession: _authentication,
      );
      expect(source.capture(), isNull);
    }

    final unauthenticated = NativeBackgroundTaskContextSourceAdapter(
      readEvidence: () => _evidence(),
      readAuthenticatedSession: () => _authentication().copyWith(ready: false),
    );
    expect(unauthenticated.capture(), isNull);

    var reads = 0;
    final torn = NativeBackgroundTaskContextSourceAdapter(
      readEvidence: () => reads++ == 0 ? _evidence() : _evidence(generation: 10),
      readAuthenticatedSession: _authentication,
    );
    expect(torn.capture(), isNull);
  });

  test('root source consumes current reachability and rejects unknown state', () {
    var state = ReachabilityState(phase: ReachabilityPhase.unknown, sessionEpoch: 7, probeGeneration: 8);
    final source = ReachabilityBackgroundTaskContextSourceAdapter(() => state, () => 'user-a');

    expect(source.capture(), isNull);

    final endpoint = Uri.parse('https://photos.example/api');
    state = ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 7,
      probeGeneration: 8,
      confirmedEndpoint: endpoint,
      serverAccess: ConfirmedServerAccess(
        apiEndpoint: endpoint,
        canonicalOrigin: Uri.parse('https://photos.example'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: 9,
        confirmed: true,
        fenced: false,
      ),
    );
    expect(source.capture()?.nativeContextGeneration, 9);
  });
}

AuthenticatedSessionEvidence _authentication() => (
  ready: true,
  token: 'opaque-token',
  userId: 'user-a',
  endpoint: 'https://photos.example/api',
  policy: EndpointSchemePolicy.httpsOnly.name,
);

extension on AuthenticatedSessionEvidence {
  AuthenticatedSessionEvidence copyWith({bool? ready}) =>
      (ready: ready ?? this.ready, token: token, userId: userId, endpoint: endpoint, policy: policy);
}

const _defaultOrigin = Object();

NativeServerAccessEvidence _evidence({
  Object? origin = _defaultOrigin,
  EndpointSchemePolicy? policy = EndpointSchemePolicy.httpsOnly,
  int generation = 9,
  bool confirmed = true,
  bool fenced = false,
}) => NativeServerAccessEvidence(
  apiEndpoint: null,
  canonicalOrigin: identical(origin, _defaultOrigin) ? Uri.parse('https://photos.example') : origin as Uri?,
  schemePolicy: policy,
  sessionEpoch: 7,
  generation: generation,
  confirmed: confirmed,
  fenced: fenced,
);
