import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

void main() {
  group('ReachabilityState', () {
    test('represents every approved reachability phase', () {
      expect(ReachabilityPhase.values, [
        ReachabilityPhase.unknown,
        ReachabilityPhase.probing,
        ReachabilityPhase.offline,
        ReachabilityPhase.online,
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
        () => ReconciliationRequest(sessionEpoch: -1, confirmedEndpoint: Uri.parse('https://photos.example.test/api')),
        throwsA(isA<ArgumentError>()),
      );
      expect(
        () => ReconciliationRequest(sessionEpoch: 0, confirmedEndpoint: Uri.parse('file:///tmp/photos')),
        throwsA(isA<ArgumentError>()),
      );
    });
  });
}
