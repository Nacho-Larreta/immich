import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/backup_run_binding_source_adapter.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';

final backupRunBindingSourceProvider = Provider<BackupRunBindingSourcePort>((ref) {
  return BackupRunBindingSourceAdapter(() => _readAtomicSnapshot(ref));
});

final backupTransportCursorProvider = StateProvider<({int epoch, int revision})>((_) => (epoch: 0, revision: 0));

typedef BackupTransportCursor = ({int epoch, int revision});

void publishBackupTransportCursor({
  required BackupTransportCursor current,
  required BackupTransportSnapshot snapshot,
  required void Function(BackupTransportCursor cursor) publish,
}) {
  final candidate = (epoch: snapshot.monitorEpoch, revision: snapshot.revision);
  if (candidate.epoch < current.epoch || (candidate.epoch == current.epoch && candidate.revision <= current.revision)) {
    return;
  }
  publish(candidate);
}

BackupBindingSnapshot _readAtomicSnapshot(Ref ref) {
  final localLease = ref.read(requestContextLeaseProvider);
  final localBefore = localLease.revision;
  final transportBefore = ref.read(backupTransportCursorProvider);
  final reachability = ref.read(serverReachabilityStateProvider);
  final userId = ref.read(currentUserProvider)?.id;
  final identity = ref.read(sessionEpochControllerProvider).current;
  if (reachability.phase == ReachabilityPhase.online) {
    return (
      userId: userId,
      identity: identity,
      reachability: reachability,
      localLeaseRevision: localBefore,
      transportEpoch: transportBefore.epoch,
      transportRevision: transportBefore.revision,
      authorityRevisionBefore: Object.hash(localBefore, transportBefore),
      authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportCursorProvider)),
    );
  }

  final context = ref.read(backgroundTaskContextSourceProvider).capture();
  if (context == null ||
      context.userId == null ||
      context.apiEndpoint == null ||
      context.canonicalOrigin == null ||
      context.schemePolicy == null) {
    return (
      userId: userId,
      identity: identity,
      reachability: reachability,
      localLeaseRevision: localBefore,
      transportEpoch: transportBefore.epoch,
      transportRevision: transportBefore.revision,
      authorityRevisionBefore: Object.hash(localBefore, transportBefore),
      authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportCursorProvider)),
    );
  }
  final workerIdentity = ReachabilityIdentity(
    sessionEpoch: context.sessionEpoch,
    probeGeneration: context.nativeContextGeneration,
  );
  return (
    userId: context.userId,
    identity: workerIdentity,
    reachability: ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: workerIdentity.sessionEpoch,
      probeGeneration: workerIdentity.probeGeneration,
      confirmedEndpoint: context.apiEndpoint,
      serverAccess: ConfirmedServerAccess(
        apiEndpoint: context.apiEndpoint!,
        canonicalOrigin: context.canonicalOrigin!,
        schemePolicy: context.schemePolicy!,
        nativeContextGeneration: context.nativeContextGeneration,
        confirmed: true,
        fenced: false,
      ),
    ),
    localLeaseRevision: localBefore,
    transportEpoch: transportBefore.epoch,
    transportRevision: transportBefore.revision,
    authorityRevisionBefore: Object.hash(localBefore, transportBefore),
    authorityRevisionAfter: Object.hash(localLease.revision, ref.read(backupTransportCursorProvider)),
  );
}
