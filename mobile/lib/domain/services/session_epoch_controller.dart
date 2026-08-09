import 'package:immich_mobile/domain/models/server_reachability.model.dart';

final class SessionEpochController {
  ReachabilityIdentity _identity = ReachabilityIdentity(sessionEpoch: 0, probeGeneration: 0);

  ReachabilityIdentity get current => _identity;

  ReachabilityIdentity beginProbeCycle() => _advanceGeneration();

  ReachabilityIdentity invalidateProbeGeneration() => _advanceGeneration();

  ReachabilityIdentity invalidateSession() {
    _identity = ReachabilityIdentity(sessionEpoch: _identity.sessionEpoch + 1, probeGeneration: 0);
    return _identity;
  }

  bool isCurrent(ReachabilityIdentity identity) => identity == _identity;

  ReachabilityIdentity _advanceGeneration() {
    _identity = ReachabilityIdentity(
      sessionEpoch: _identity.sessionEpoch,
      probeGeneration: _identity.probeGeneration + 1,
    );
    return _identity;
  }
}
