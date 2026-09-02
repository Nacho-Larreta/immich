import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/models/backup_candidate_key.model.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_reconciliation_quarantine.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

final class DriftBackupExecutionLeaseRepository implements BackupExecutionLeasePort {
  const DriftBackupExecutionLeaseRepository(this._db);

  final Drift _db;

  @override
  Future<BackupExecutionLease?> read() async {
    final row = await (_db.storeEntity.select()..where((entry) => entry.id.equals(StoreKey.backupExecutionLease.id)))
        .getSingleOrNull();
    return BackupExecutionLease.tryParse(row?.stringValue);
  }

  @override
  Future<bool> acquire(BackupExecutionLease candidate, DateTime now) async {
    final affected = await _db.customUpdate(
      '''
      INSERT INTO store_entity (id, string_value, int_value)
      SELECT ?1, ?2, NULL
      WHERE EXISTS (
        SELECT 1 FROM store_entity AS enablement
        WHERE enablement.id = ?5
          AND json_valid(enablement.string_value)
          AND CAST(json_extract(enablement.string_value, '\$.schemaVersion') AS INTEGER) = 1
          AND json_extract(enablement.string_value, '\$.phase') = 'enabled'
      )
      ON CONFLICT(id) DO UPDATE SET string_value = excluded.string_value, int_value = NULL
      WHERE EXISTS (
          SELECT 1 FROM store_entity AS enablement
          WHERE enablement.id = ?5
            AND json_valid(enablement.string_value)
            AND CAST(json_extract(enablement.string_value, '\$.schemaVersion') AS INTEGER) = 1
            AND json_extract(enablement.string_value, '\$.phase') = 'enabled'
        )
        AND (
          NOT json_valid(store_entity.string_value)
          OR COALESCE(CAST(json_extract(store_entity.string_value, '\$.schemaVersion') AS INTEGER), -1) != ?4
          OR (
            CAST(json_extract(store_entity.string_value, '\$.expiryEpochMs') AS INTEGER) <= ?3
            AND json_extract(store_entity.string_value, '\$.state') = 'accepting'
            AND COALESCE(CAST(json_extract(store_entity.string_value, '\$.callbacksInFlight') AS INTEGER), 0) = 0
            AND COALESCE(json_array_length(json_extract(store_entity.string_value, '\$.outstandingClaims')), 0) = 0
            AND COALESCE(json_array_length(json_extract(store_entity.string_value, '\$.enqueueClaims')), 0) = 0
            AND COALESCE(json_array_length(json_extract(store_entity.string_value, '\$.terminalTombstones')), 0) = 0
            AND COALESCE(json_array_length(json_extract(store_entity.string_value, '\$.callbackClaims')), 0) = 0
            AND COALESCE(json_array_length(json_extract(store_entity.string_value, '\$.reconciliationClaims')), 0) = 0
            AND COALESCE(json_array_length(json_extract(store_entity.string_value, '\$.foregroundActivityClaims')), 0) = 0
          )
        )
      ''',
      variables: [
        Variable.withInt(StoreKey.backupExecutionLease.id),
        Variable.withString(candidate.toJson()),
        Variable.withInt(now.toUtc().millisecondsSinceEpoch),
        Variable.withInt(BackupExecutionLease.schemaVersion),
        Variable.withInt(StoreKey.backupEnablementState.id),
      ],
      updates: {_db.storeEntity},
    );
    return affected == 1;
  }

  @override
  Future<bool> replaceExact({required BackupExecutionLease expected, required BackupExecutionLease replacement}) {
    return _replaceExact(expected.toJson(), replacement.toJson());
  }

  @override
  Future<bool> releaseExact(BackupExecutionLease expected) async {
    final affected = await _db.customUpdate(
      'DELETE FROM store_entity WHERE id = ?1 AND string_value = ?2',
      variables: [Variable.withInt(StoreKey.backupExecutionLease.id), Variable.withString(expected.toJson())],
      updates: {_db.storeEntity},
    );
    return affected == 1;
  }

  @override
  Future<BackupExecutionLease?> beginCallback(BackupExecutionLease expected) => _transition(
    expected,
    expected.state == BackupExecutionState.closing
        ? null
        : expected.copyWith(
            callbacksInFlight: expected.callbacksInFlight + 1,
            activityRevision: expected.activityRevision + 1,
          ),
  );

  @override
  Future<BackupExecutionLease?> endCallback(BackupExecutionLease expected) {
    if (expected.callbacksInFlight == 0) return Future.value();
    return _transition(
      expected,
      expected.copyWith(
        callbacksInFlight: expected.callbacksInFlight - 1,
        activityRevision: expected.activityRevision + 1,
      ),
    );
  }

  @override
  Future<BackupExecutionLease?> markEnqueued(BackupExecutionLease expected) =>
      _transition(expected, expected.copyWith(activityRevision: expected.activityRevision + 1));

  @override
  Future<BackupExecutionLease?> beginCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      final knownClaim = lease.enqueueClaims.contains(claim) || lease.outstandingClaims.contains(claim);
      if (!knownClaim || lease.terminalTombstones.contains(claim) || lease.callbackClaims.contains(claim)) return null;
      return lease.copyWith(
        callbacksInFlight: lease.callbacksInFlight + 1,
        callbackClaims: {...lease.callbackClaims, claim},
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> endCallbackForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) => lease.callbacksInFlight == 0 || !lease.callbackClaims.contains(claim)
        ? null
        : lease.copyWith(
            callbacksInFlight: lease.callbacksInFlight - 1,
            callbackClaims: {...lease.callbackClaims}..remove(claim),
            activityRevision: lease.activityRevision + 1,
          ),
  );

  @override
  Future<BackupExecutionLease?> markEnqueuedForTask({required String runToken, required String bindingDigest}) =>
      _transitionForTask(
        runToken: runToken,
        bindingDigest: bindingDigest,
        replacement: (lease) => lease.copyWith(activityRevision: lease.activityRevision + 1),
      );

  @override
  Future<BackupExecutionLease?> beginEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    requireBackupEnabled: true,
    replacement: (lease) {
      if (lease.state == BackupExecutionState.closing) return null;
      if (lease.terminalTombstones.contains(claim)) return null;
      if (lease.enqueueClaims.contains(claim) || lease.outstandingClaims.contains(claim)) return lease;
      return lease.copyWith(
        enqueueClaims: {...lease.enqueueClaims, claim},
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> beginEnqueueUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
  }) {
    return _db.transaction(() async {
      final key = BackupCandidateKey.parse(candidateKey).value;
      final quarantine = await _readQuarantine();
      if (quarantine == null || quarantine.entries.any((entry) => entry.candidateKey == key)) return null;
      final expected = await read();
      if (expected == null ||
          expected.runToken != runToken ||
          expected.bindingDigest != bindingDigest ||
          expected.state == BackupExecutionState.closing ||
          expected.terminalTombstones.contains(claim)) {
        return null;
      }
      if (expected.enqueueClaims.contains(claim) || expected.outstandingClaims.contains(claim)) return expected;
      final replacement = expected.copyWith(
        enqueueClaims: {...expected.enqueueClaims, claim},
        candidateKeys: {...expected.candidateKeys, claim: key},
        activityRevision: expected.activityRevision + 1,
      );
      return await _replaceExactWhenBackupEnabled(expected, replacement) ? replacement : null;
    });
  }

  @override
  Future<bool> allowForegroundCandidateUnlessQuarantined({
    required String runToken,
    required String bindingDigest,
    required String candidateKey,
  }) {
    return _db.transaction(() async {
      final key = BackupCandidateKey.parse(candidateKey).value;
      final quarantine = await _readQuarantine();
      if (quarantine == null || quarantine.entries.any((entry) => entry.candidateKey == key)) return false;
      final lease = await read();
      return lease != null &&
          await _backupEnabled() &&
          lease.runToken == runToken &&
          lease.bindingDigest == bindingDigest &&
          lease.state == BackupExecutionState.accepting &&
          lease.foregroundActivityClaims.isNotEmpty;
    });
  }

  @override
  Future<BackupExecutionLease?> confirmEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      if (lease.terminalTombstones.contains(claim)) {
        return lease.copyWith(
          terminalTombstones: {...lease.terminalTombstones}..remove(claim),
          candidateKeys: {...lease.candidateKeys}..remove(claim),
          activityRevision: lease.activityRevision + 1,
        );
      }
      if (lease.outstandingClaims.contains(claim)) return lease;
      if (!lease.enqueueClaims.contains(claim)) return null;
      return lease.copyWith(
        enqueueClaims: {...lease.enqueueClaims}..remove(claim),
        outstandingClaims: {...lease.outstandingClaims, claim},
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> abortEnqueueForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      if (!lease.enqueueClaims.contains(claim)) return lease;
      return lease.copyWith(
        enqueueClaims: {...lease.enqueueClaims}..remove(claim),
        candidateKeys: {...lease.candidateKeys}..remove(claim),
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> consumeTerminalForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      if (lease.terminalTombstones.contains(claim)) return lease;
      if (lease.enqueueClaims.contains(claim)) {
        return lease.copyWith(
          enqueueClaims: {...lease.enqueueClaims}..remove(claim),
          terminalTombstones: {...lease.terminalTombstones, claim},
          activityRevision: lease.activityRevision + 1,
        );
      }
      if (!lease.outstandingClaims.contains(claim)) return lease;
      return lease.copyWith(
        outstandingClaims: {...lease.outstandingClaims}..remove(claim),
        candidateKeys: {...lease.candidateKeys}..remove(claim),
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> markReconciliationPendingForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      if (lease.reconciliationClaims.contains(claim)) return lease;
      if (!lease.outstandingClaims.contains(claim) && !lease.enqueueClaims.contains(claim)) return null;
      return lease.copyWith(
        outstandingClaims: {...lease.outstandingClaims}..remove(claim),
        enqueueClaims: {...lease.enqueueClaims}..remove(claim),
        reconciliationClaims: {...lease.reconciliationClaims, claim},
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> completeReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      if (!lease.reconciliationClaims.contains(claim)) return null;
      return lease.copyWith(
        reconciliationClaims: {...lease.reconciliationClaims}..remove(claim),
        candidateKeys: {...lease.candidateKeys}..remove(claim),
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<Set<BackupReconciliationQuarantineEntry>> readReconciliationQuarantine() async {
    final quarantine = await _readQuarantine();
    if (quarantine == null) throw const FormatException('Malformed backup reconciliation quarantine');
    return quarantine.entries;
  }

  @override
  Future<BackupExecutionLease?> quarantineReconciliationForTask({
    required String runToken,
    required String bindingDigest,
    required BackupTaskClaim claim,
    required String candidateKey,
    required BackupReconciliationQuarantineCode code,
  }) {
    return _db.transaction(() async {
      final key = BackupCandidateKey.parse(candidateKey).value;
      final quarantine = await _readQuarantine();
      if (quarantine == null) return null;
      final expected = await read();
      if (expected == null ||
          expected.runToken != runToken ||
          expected.bindingDigest != bindingDigest ||
          !expected.reconciliationClaims.contains(claim)) {
        return null;
      }
      final replacement = expected.copyWith(
        reconciliationClaims: {...expected.reconciliationClaims}..remove(claim),
        candidateKeys: {...expected.candidateKeys}..remove(claim),
        activityRevision: expected.activityRevision + 1,
      );
      if (!await replaceExact(expected: expected, replacement: replacement)) return null;

      final updatedQuarantine = quarantine.add(
        BackupReconciliationQuarantineEntry(claim: claim, candidateKey: key, bindingDigest: bindingDigest, code: code),
      );
      await _db.customUpdate(
        '''
        INSERT INTO store_entity (id, string_value, int_value)
        VALUES (?1, ?2, NULL)
        ON CONFLICT(id) DO UPDATE SET string_value = excluded.string_value, int_value = NULL
        ''',
        variables: [
          Variable.withInt(StoreKey.backupReconciliationQuarantine.id),
          Variable.withString(updatedQuarantine.toJson()),
        ],
        updates: {_db.storeEntity},
      );
      return replacement;
    });
  }

  Future<BackupReconciliationQuarantine?> _readQuarantine() async {
    final row =
        await (_db.storeEntity.select()..where((entry) => entry.id.equals(StoreKey.backupReconciliationQuarantine.id)))
            .getSingleOrNull();
    return BackupReconciliationQuarantine.tryParse(row?.stringValue);
  }

  @override
  Future<BackupExecutionLease?> reconcileTaskClaimsForOwner({
    required String runToken,
    required String bindingDigest,
    required Set<BackupTaskClaim> activeClaims,
  }) {
    return _transitionForTask(
      runToken: runToken,
      bindingDigest: bindingDigest,
      replacement: (lease) {
        final outstanding = lease.state == BackupExecutionState.closing
            ? lease.outstandingClaims.intersection(activeClaims)
            : activeClaims;
        final enqueue = lease.enqueueClaims.difference(activeClaims);
        if (_sameClaims(outstanding, lease.outstandingClaims) && _sameClaims(enqueue, lease.enqueueClaims)) {
          return lease;
        }
        return lease.copyWith(
          outstandingClaims: outstanding,
          enqueueClaims: enqueue,
          activityRevision: lease.activityRevision + 1,
        );
      },
    );
  }

  @override
  Future<BackupExecutionLease?> recoverExpiredClosingExact({
    required BackupExecutionLease expected,
    required Set<BackupTaskClaim> activeClaims,
  }) {
    if (expected.state != BackupExecutionState.closing) return Future.value();
    final outstanding = activeClaims;
    final enqueue = expected.enqueueClaims.difference(activeClaims);
    final tombstones = activeClaims.isEmpty ? const <BackupTaskClaim>{} : expected.terminalTombstones;
    final alreadyRecovered =
        _sameClaims(outstanding, expected.outstandingClaims) &&
        _sameClaims(enqueue, expected.enqueueClaims) &&
        _sameClaims(tombstones, expected.terminalTombstones) &&
        expected.callbackClaims.isEmpty &&
        expected.callbacksInFlight == 0 &&
        expected.foregroundActivityClaims.isEmpty;
    if (alreadyRecovered) return Future.value(expected);
    return _transition(
      expected,
      expected.copyWith(
        outstandingClaims: outstanding,
        enqueueClaims: enqueue,
        terminalTombstones: tombstones,
        callbacksInFlight: 0,
        callbackClaims: const {},
        foregroundActivityClaims: const {},
        activityRevision: expected.activityRevision + 1,
      ),
    );
  }

  @override
  Future<BackupExecutionLease?> beginClosingForOwner({required String runToken, required String bindingDigest}) =>
      _transitionForTask(
        runToken: runToken,
        bindingDigest: bindingDigest,
        replacement: (lease) => lease.state == BackupExecutionState.closing
            ? lease
            : lease.copyWith(state: BackupExecutionState.closing, activityRevision: lease.activityRevision + 1),
      );

  @override
  Future<BackupExecutionLease?> beginForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    requireBackupEnabled: true,
    replacement: (lease) {
      if (claim.bindingDigest != bindingDigest || lease.state == BackupExecutionState.closing) return null;
      if (lease.foregroundActivityClaims.contains(claim)) return lease;
      return lease.copyWith(
        foregroundActivityClaims: {...lease.foregroundActivityClaims, claim},
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  @override
  Future<BackupExecutionLease?> endForegroundActivityForOwner({
    required String runToken,
    required String bindingDigest,
    required ForegroundTransportClaim claim,
  }) => _transitionForTask(
    runToken: runToken,
    bindingDigest: bindingDigest,
    replacement: (lease) {
      if (!lease.foregroundActivityClaims.contains(claim)) return lease;
      return lease.copyWith(
        foregroundActivityClaims: {...lease.foregroundActivityClaims}..remove(claim),
        activityRevision: lease.activityRevision + 1,
      );
    },
  );

  Future<BackupExecutionLease?> _transition(BackupExecutionLease expected, BackupExecutionLease? replacement) async {
    if (replacement == null) return null;
    if (replacement == expected) return expected;
    return await replaceExact(expected: expected, replacement: replacement) ? replacement : null;
  }

  Future<BackupExecutionLease?> _transitionForTask({
    required String runToken,
    required String bindingDigest,
    required BackupExecutionLease? Function(BackupExecutionLease lease) replacement,
    bool requireBackupEnabled = false,
  }) async {
    var contentionDelay = const Duration(milliseconds: 1);
    while (true) {
      final expected = await read();
      if (expected == null || expected.runToken != runToken || expected.bindingDigest != bindingDigest) return null;
      final next = replacement(expected);
      if (next == null) return null;
      if (next == expected) return requireBackupEnabled && !await _backupEnabled() ? null : expected;
      final replaced = requireBackupEnabled
          ? await _replaceExactWhenBackupEnabled(expected, next)
          : await replaceExact(expected: expected, replacement: next);
      if (replaced) return next;
      if (requireBackupEnabled && !await _backupEnabled()) return null;
      await Future<void>.delayed(contentionDelay);
      if (contentionDelay < const Duration(milliseconds: 16)) contentionDelay *= 2;
    }
  }

  static bool _sameClaims<T>(Set<T> left, Set<T> right) => left.length == right.length && left.containsAll(right);

  Future<bool> _replaceExact(String expected, String replacement) async {
    final affected = await _db.customUpdate(
      'UPDATE store_entity SET string_value = ?1, int_value = NULL WHERE id = ?2 AND string_value = ?3',
      variables: [
        Variable.withString(replacement),
        Variable.withInt(StoreKey.backupExecutionLease.id),
        Variable.withString(expected),
      ],
      updates: {_db.storeEntity},
    );
    return affected == 1;
  }

  Future<bool> _replaceExactWhenBackupEnabled(BackupExecutionLease expected, BackupExecutionLease replacement) async {
    final affected = await _db.customUpdate(
      '''
      UPDATE store_entity
      SET string_value = ?1, int_value = NULL
      WHERE id = ?2
        AND string_value = ?3
        AND EXISTS (
          SELECT 1 FROM store_entity AS enablement
          WHERE enablement.id = ?4
            AND json_valid(enablement.string_value)
            AND CAST(json_extract(enablement.string_value, '\$.schemaVersion') AS INTEGER) = 1
            AND json_extract(enablement.string_value, '\$.phase') = 'enabled'
        )
      ''',
      variables: [
        Variable.withString(replacement.toJson()),
        Variable.withInt(StoreKey.backupExecutionLease.id),
        Variable.withString(expected.toJson()),
        Variable.withInt(StoreKey.backupEnablementState.id),
      ],
      updates: {_db.storeEntity},
    );
    return affected == 1;
  }

  Future<bool> _backupEnabled() async {
    final setting = await _db
        .customSelect(
          'SELECT string_value FROM store_entity WHERE id = ?1',
          variables: [Variable.withInt(StoreKey.backupEnablementState.id)],
        )
        .getSingleOrNull();
    return DurableBackupEnablementState.tryParse(setting?.read<String?>('string_value'))?.phase ==
        DurableBackupEnablementPhase.enabled;
  }
}
