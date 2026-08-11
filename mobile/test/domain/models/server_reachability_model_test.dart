import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

void main() {
  group('ReachabilityState', () {
    test('represents every approved reachability phase', () {
      expect(ReachabilityPhase.values, [
        ReachabilityPhase.unknown,
        ReachabilityPhase.probing,
        ReachabilityPhase.offline,
        ReachabilityPhase.online,
        ReachabilityPhase.paused,
        ReachabilityPhase.disposed,
      ]);
    });

    test('keeps session and probe generations in the value identity', () {
      final endpoint = Uri.parse('https://photos.example.test/api');
      final first = ReachabilityState(
        phase: ReachabilityPhase.probing,
        sessionEpoch: 3,
        confirmedEndpoint: endpoint,
        probeGeneration: 7,
      );
      final same = ReachabilityState(
        phase: ReachabilityPhase.probing,
        sessionEpoch: 3,
        confirmedEndpoint: endpoint,
        probeGeneration: 7,
      );

      expect(first, same);
      expect(first.hashCode, same.hashCode);
      expect(first, isNot(same.copyWith(probeGeneration: 8)));
      expect(first, isNot(same.copyWith(sessionEpoch: 4)));
    });

    test('requires a confirmed endpoint before becoming online', () {
      expect(
        () => ReachabilityState(phase: ReachabilityPhase.online, sessionEpoch: 0, probeGeneration: 0),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('can clear the confirmed endpoint when leaving online state', () {
      final online = ReachabilityState(
        phase: ReachabilityPhase.online,
        sessionEpoch: 1,
        confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
        probeGeneration: 2,
      );

      final loggedOut = online.copyWith(phase: ReachabilityPhase.offline, confirmedEndpoint: null);

      expect(loggedOut.phase, ReachabilityPhase.offline);
      expect(loggedOut.confirmedEndpoint, isNull);
    });

    test('can explicitly clear immutable server access proof', () {
      final proof = ConfirmedServerAccess(
        apiEndpoint: Uri.parse('https://photos.example.test/api'),
        canonicalOrigin: Uri.parse('https://photos.example.test'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: 4,
        confirmed: true,
        fenced: false,
      );
      final state = ReachabilityState(
        phase: ReachabilityPhase.probing,
        sessionEpoch: 1,
        confirmedEndpoint: proof.apiEndpoint,
        serverAccess: proof,
        probeGeneration: 2,
      );

      final cleared = state.copyWith(confirmedEndpoint: null, serverAccess: null);

      expect(cleared.confirmedEndpoint, isNull);
      expect(cleared.serverAccess, isNull);
    });

    test('rejects negative generations', () {
      expect(
        () => ReachabilityState(phase: ReachabilityPhase.unknown, sessionEpoch: -1, probeGeneration: 0),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ReachabilityState(phase: ReachabilityPhase.unknown, sessionEpoch: 0, probeGeneration: -1),
        throwsA(isA<ArgumentError>()),
      );
    });

    test('reconciliation request validates endpoint and epoch at runtime', () {
      expect(
        () => ReconciliationRequest(
          sessionEpoch: -1,
          probeGeneration: 0,
          confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ReconciliationRequest(
          sessionEpoch: 0,
          probeGeneration: -1,
          confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
        ),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ReconciliationRequest(
          sessionEpoch: 0,
          probeGeneration: 0,
          confirmedEndpoint: Uri.parse('file:///tmp/photos'),
        ),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
