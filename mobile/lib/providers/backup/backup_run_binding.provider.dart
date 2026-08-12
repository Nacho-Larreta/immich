import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:flutter/foundation.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/backup_run_binding_source_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

final backupRunBindingSourceProvider = Provider<BackupRunBindingSourcePort>((ref) {
  return BackupRunBindingSourceAdapter(() => _readAtomicSnapshot(ref));
});

final backupTransportRevisionProvider = StateProvider<int>((_) => 0);

BackupBindingSnapshot _readAtomicSnapshot(Ref ref) {
  final localLease = ref.read(requestContextLeaseProvider);
  final localBefore = localLease.revision;
  final transportBefore = ref.read(backupTransportRevisionProvider);
  final reachability = ref.read(serverReachabilityStateProvider);
  final userId = ref.read(currentUserProvider)?.id;
  final identity = ref.read(sessionEpochControllerProvider).current;
  if (reachability.phase == ReachabilityPhase.online) {
    return (
      userId: userId,
      identity: identity,
      reachability: reachability,
      localLeaseRevision: localBefore,
      transportRevision: transportBefore,
      authorityRevisionBefore: Object.hash(localBefore, transportBefore),
      authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportRevisionProvider)),
    );
  }

  final evidence = NetworkRepository.serverAccessEvidence;
  final endpoint = resolveAttachedWorkerEndpoint(
    persistedEndpoint: Store.tryGet(StoreKey.serverEndpoint),
    evidence: evidence,
  );
  final origin = evidence.canonicalOrigin;
  final policy = evidence.schemePolicy;
  if (!evidence.confirmed || evidence.fenced || endpoint == null || origin == null || policy == null) {
    return (
      userId: userId,
      identity: identity,
      reachability: reachability,
      localLeaseRevision: localBefore,
      transportRevision: transportBefore,
      authorityRevisionBefore: Object.hash(localBefore, transportBefore),
      authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportRevisionProvider)),
    );
  }
  final evidenceAfter = NetworkRepository.serverAccessEvidence;
  final identityAfter = ref.read(sessionEpochControllerProvider).current;
  final userIdAfter = ref.read(currentUserProvider)?.id;
  if (evidence.sessionEpoch != identity.sessionEpoch ||
      !_sameNativeEvidence(evidence, evidenceAfter) ||
      identityAfter.sessionEpoch != identity.sessionEpoch ||
      identityAfter.probeGeneration != identity.probeGeneration ||
      userIdAfter != userId) {
    return (
      userId: userId,
      identity: identity,
      reachability: reachability,
      localLeaseRevision: localBefore,
      transportRevision: transportBefore,
      authorityRevisionBefore: Object.hash(localBefore, transportBefore),
      authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportRevisionProvider)),
    );
  }
  final workerIdentity = ReachabilityIdentity(
    sessionEpoch: evidence.sessionEpoch,
    probeGeneration: evidence.generation,
  );
  return (
    userId: userId,
    identity: workerIdentity,
    reachability: ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: workerIdentity.sessionEpoch,
      probeGeneration: workerIdentity.probeGeneration,
      confirmedEndpoint: endpoint,
      serverAccess: ConfirmedServerAccess(
        apiEndpoint: endpoint,
        canonicalOrigin: origin,
        schemePolicy: policy,
        nativeContextGeneration: evidence.generation,
        confirmed: evidence.confirmed,
        fenced: evidence.fenced,
      ),
    ),
    localLeaseRevision: localBefore,
    transportRevision: transportBefore,
    authorityRevisionBefore: Object.hash(localBefore, transportBefore),
    authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportRevisionProvider)),
  );
}

@visibleForTesting
Uri? resolveAttachedWorkerEndpoint({required String? persistedEndpoint, required NativeServerAccessEvidence evidence}) {
  final endpoint = evidence.apiEndpoint ?? Uri.tryParse(persistedEndpoint ?? '');
  final origin = evidence.canonicalOrigin;
  final policy = evidence.schemePolicy;
  if (endpoint == null || origin == null || policy == null) return null;
  try {
    if (endpoint.origin != origin.origin ||
        endpoint.pathSegments.where((segment) => segment.isNotEmpty).last != 'api') {
      return null;
    }
    validateEndpointSchemePolicy(origin, policy);
    return endpoint;
  } on Object {
    return null;
  }
}

bool _sameNativeEvidence(NativeServerAccessEvidence left, NativeServerAccessEvidence right) =>
    left.apiEndpoint == right.apiEndpoint &&
    left.canonicalOrigin == right.canonicalOrigin &&
    left.schemePolicy == right.schemePolicy &&
    left.sessionEpoch == right.sessionEpoch &&
    left.generation == right.generation &&
    left.confirmed == right.confirmed &&
    left.fenced == right.fenced;
