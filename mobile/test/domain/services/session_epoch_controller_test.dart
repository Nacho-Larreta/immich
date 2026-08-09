import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';

void main() {
  test('advances probe generation without changing the session epoch', () {
    final epochs = SessionEpochController();

    expect(epochs.current, ReachabilityIdentity(sessionEpoch: 0, probeGeneration: 0));
    expect(epochs.beginProbeCycle(), ReachabilityIdentity(sessionEpoch: 0, probeGeneration: 1));
    expect(epochs.invalidateProbeGeneration(), ReachabilityIdentity(sessionEpoch: 0, probeGeneration: 2));
  });

  test('invalidates the session synchronously and resets its probe generation', () {
    final epochs = SessionEpochController();
    final stale = epochs.beginProbeCycle();

    final current = epochs.invalidateSession();

    expect(current, ReachabilityIdentity(sessionEpoch: 1, probeGeneration: 0));
    expect(epochs.isCurrent(stale), isFalse);
    expect(epochs.isCurrent(current), isTrue);
  });
}
