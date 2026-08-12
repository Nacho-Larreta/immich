import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

typedef BackupBindingSnapshot = ({
  String? userId,
  ReachabilityIdentity identity,
  ReachabilityState reachability,
  int localLeaseRevision,
  int transportEpoch,
  int transportRevision,
  int authorityRevisionBefore,
  int authorityRevisionAfter,
});

typedef BackupBindingSnapshotReader = BackupBindingSnapshot Function();

final class BackupRunBindingSourceAdapter implements BackupRunBindingSourcePort {
  const BackupRunBindingSourceAdapter(this._readSnapshot);

  final BackupBindingSnapshotReader _readSnapshot;

  @override
  BackupRunBinding? capture() {
    final snapshot = _readSnapshot();
    final userId = snapshot.userId;
    final reachability = snapshot.reachability;
    final access = reachability.serverAccess;
    if (userId == null ||
        userId.isEmpty ||
        snapshot.identity.sessionEpoch != reachability.sessionEpoch ||
        snapshot.identity.probeGeneration != reachability.probeGeneration ||
        reachability.phase != ReachabilityPhase.online ||
        access == null ||
        !access.isCurrent ||
        reachability.confirmedEndpoint != access.apiEndpoint ||
        snapshot.authorityRevisionBefore != snapshot.authorityRevisionAfter) {
      return null;
    }

    return BackupRunBinding(
      userId: userId,
      sessionEpoch: reachability.sessionEpoch,
      probeGeneration: reachability.probeGeneration,
      nativeGeneration: access.nativeContextGeneration,
      apiEndpoint: access.apiEndpoint,
      canonicalOrigin: access.canonicalOrigin,
      schemePolicy: access.schemePolicy,
      transportEpoch: snapshot.transportEpoch,
      transportRevision: snapshot.transportRevision,
      localLeaseRevision: snapshot.localLeaseRevision,
    );
  }

  @override
  bool isCurrent(BackupRunBinding binding) => capture() == binding;
}
