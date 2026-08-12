import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_reconciliation_quarantine.model.dart';

abstract interface class BackupExecutionLeasePort {
  Future<BackupExecutionLease?> read();

  Future<bool> acquire(BackupExecutionLease candidate, DateTime now);

  Future<bool> replaceExact({required BackupExecutionLease expected, required BackupExecutionLease replacement});

  Future<bool> releaseExact(BackupExecutionLease expected);

  Future<BackupExecutionLease?> beginCallback(BackupExecutionLease expected);

  Future<BackupExecutionLease?> endCallback(BackupExecutionLease expected);

  Future<BackupExecutionLease?> markEnqueued(BackupExecutionLease expected);

  Future<BackupExecutionLease?> beginCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> endCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> markEnqueuedForTask({required String runToken, required String bindingDigest});

  Future<BackupExecutionLease?> beginEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> beginEnqueueUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
  });

  Future<bool> allowForegroundCandidateUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required String candidateKey,
  });

  Future<BackupExecutionLease?> confirmEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> abortEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> consumeTerminalForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> markReconciliationPendingForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> completeReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  });

  Future<BackupExecutionLease?> quarantineReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
    required BackupReconciliationQuarantineCode code,
  });

  Future<Set<BackupReconciliationQuarantineEntry>> readReconciliationQuarantine();

  Future<BackupExecutionLease?> reconcileTaskClaimsForOwner({
    required String runToken,
    required String bindingDigest,
    required Set<BackupTaskClaim> activeClaims,
  });

  Future<BackupExecutionLease?> recoverOrphanClaimsForOwner({
    required String runToken,
    required String bindingDigest,
    required Set<BackupTaskClaim> activeClaims,
  });

  Future<BackupExecutionLease?> beginClosingForOwner({required String runToken, required String bindingDigest});

  Future<BackupExecutionLease?> beginForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  });

  Future<BackupExecutionLease?> endForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  });

  Future<BackupExecutionLease?> clearForegroundActivitiesForOwner({
    required String runToken,
    required String bindingDigest,
    required Set<ForegroundTransportClaim> expectedClaims,
  });
}

abstract interface class BackupTaskRegistryPort {
  Future<void> get ready;

  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups);

  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups);
}

abstract interface class ForegroundTransportFencePort {
  Future<bool> fenceAndDrain(ForegroundTransportClaim claim);
}
