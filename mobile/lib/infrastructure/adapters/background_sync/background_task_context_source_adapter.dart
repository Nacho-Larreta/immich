import 'package:immich_mobile/domain/interfaces/background_task_context_source.interface.dart';
import 'package:immich_mobile/domain/models/background_task.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

final class ReachabilityBackgroundTaskContextSourceAdapter implements BackgroundTaskContextSourcePort {
  const ReachabilityBackgroundTaskContextSourceAdapter(this._readState, this._readUserId);

  final ReachabilityState Function() _readState;
  final String? Function() _readUserId;

  @override
  BackgroundTaskContextBinding? capture() {
    final state = _readState();
    final userId = _readUserId();
    final proof = state.serverAccess;
    if (userId == null ||
        userId.isEmpty ||
        state.phase != ReachabilityPhase.online ||
        proof == null ||
        !proof.isCurrent ||
        state.confirmedEndpoint != proof.apiEndpoint) {
      return null;
    }
    return BackgroundTaskContextBinding(
      sessionEpoch: state.sessionEpoch,
      nativeContextGeneration: proof.nativeContextGeneration,
      userId: userId,
      apiEndpoint: proof.apiEndpoint,
      canonicalOrigin: proof.canonicalOrigin,
      schemePolicy: proof.schemePolicy,
    );
  }
}

typedef NativeServerAccessEvidenceReader = NativeServerAccessEvidence Function();
typedef AuthenticatedSessionEvidence = ({bool ready, String? token, String? userId, String? endpoint, String? policy});

final class NativeBackgroundTaskContextSourceAdapter implements BackgroundTaskContextSourcePort {
  const NativeBackgroundTaskContextSourceAdapter({
    required NativeServerAccessEvidenceReader readEvidence,
    required AuthenticatedSessionEvidence Function() readAuthenticatedSession,
  }) : _readEvidence = readEvidence,
       _readAuthenticatedSession = readAuthenticatedSession;

  final NativeServerAccessEvidenceReader _readEvidence;
  final AuthenticatedSessionEvidence Function() _readAuthenticatedSession;

  @override
  BackgroundTaskContextBinding? capture() {
    final before = _readEvidence();
    final authBefore = _readAuthenticatedSession();
    final after = _readEvidence();
    final authAfter = _readAuthenticatedSession();
    if (!_sameEvidence(before, after) ||
        authBefore != authAfter ||
        !authBefore.ready ||
        (authBefore.token ?? '').isEmpty ||
        (authBefore.userId ?? '').isEmpty ||
        !before.confirmed ||
        before.fenced) {
      return null;
    }

    final origin = before.canonicalOrigin;
    final policy = before.schemePolicy;
    final endpoint = before.apiEndpoint ?? Uri.tryParse(authBefore.endpoint ?? '');
    if (origin == null || policy == null || endpoint == null || authBefore.policy != policy.name) return null;
    try {
      validateHttpEndpoint(endpoint, 'apiEndpoint');
      validateHttpOrigin(origin, 'canonicalOrigin');
      validateEndpointSchemePolicy(origin, policy);
      if (endpoint.origin != origin.origin ||
          endpoint.pathSegments.where((segment) => segment.isNotEmpty).last != 'api') {
        return null;
      }
    } on Object {
      return null;
    }
    return BackgroundTaskContextBinding(
      sessionEpoch: before.sessionEpoch,
      nativeContextGeneration: before.generation,
      userId: authBefore.userId,
      apiEndpoint: endpoint,
      canonicalOrigin: origin,
      schemePolicy: policy,
    );
  }
}

bool _sameEvidence(NativeServerAccessEvidence left, NativeServerAccessEvidence right) =>
    left.apiEndpoint == right.apiEndpoint &&
    left.canonicalOrigin == right.canonicalOrigin &&
    left.schemePolicy == right.schemePolicy &&
    left.sessionEpoch == right.sessionEpoch &&
    left.generation == right.generation &&
    left.confirmed == right.confirmed &&
    left.fenced == right.fenced;
