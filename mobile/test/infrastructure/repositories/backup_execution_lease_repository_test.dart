import 'dart:io';

import 'package:drift/drift.dart' hide isNull, isNotNull;
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';
import 'package:immich_mobile/domain/models/backup_candidate_key.model.dart';
import 'package:immich_mobile/domain/models/backup_reconciliation_quarantine.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

void main() {
  late Directory directory;
  late Drift firstDb;
  late Drift secondDb;
  late DriftBackupExecutionLeaseRepository first;
  late DriftBackupExecutionLeaseRepository second;

  setUp(() async {
    directory = await Directory.systemTemp.createTemp('immich-backup-lease-');
    final file = File('${directory.path}/shared.sqlite');
    firstDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await firstDb.customSelect('SELECT 1').get();
    await _setBackupEnabled(firstDb, true);
    secondDb = Drift(DatabaseConnection(NativeDatabase(file), closeStreamsSynchronously: true));
    await secondDb.customSelect('SELECT 1').get();
    first = DriftBackupExecutionLeaseRepository(firstDb);
    second = DriftBackupExecutionLeaseRepository(secondDb);
  });

  tearDown(() async {
    await secondDb.close();
    await firstDb.close();
    await directory.delete(recursive: true);
  });

  test('two connections race and exactly one acquires', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final candidates = [_lease('first', now), _lease('second', now)];

    final results = await Future.wait([first.acquire(candidates[0], now), second.acquire(candidates[1], now)]);

    expect(results.where((result) => result), hasLength(1));
    expect((await first.read())?.runToken, anyOf('first', 'second'));
  });

  test('lease acquisition fails closed when backup setting is absent or disabled', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    await firstDb.customUpdate(
      'DELETE FROM store_entity WHERE id IN (?1, ?2)',
      variables: [Variable.withInt(StoreKey.enableBackup.id), Variable.withInt(StoreKey.backupEnablementState.id)],
    );

    expect(await first.acquire(_lease('missing-setting', now), now), isFalse);
    expect(await first.read(), isNull);

    await _setBackupEnabled(firstDb, false);
    expect(await first.acquire(_lease('disabled-setting', now), now), isFalse);
    expect(await first.read(), isNull);
  });

  test('stale worker cannot acquire after backup is atomically disabled', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    const staleCachedSetting = true;
    expect(staleCachedSetting, isTrue);
    await _setBackupEnabled(secondDb, false);

    expect(await first.acquire(_lease('stale-worker', now), now), isFalse);
    expect(await second.read(), isNull);
  });

  test('existing owner cannot reserve new work after backup is disabled', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('existing-owner', now);
    expect(await first.acquire(lease, now), isTrue);
    await _setBackupEnabled(secondDb, false);

    expect(
      await first.beginEnqueueForTask(
        runToken: lease.runToken,
        bindingDigest: lease.bindingDigest,
        claim: const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'denied-after-off'),
      ),
      isNull,
    );
    expect(
      await second.beginForegroundActivityForOwner(
        runToken: lease.runToken,
        bindingDigest: lease.bindingDigest,
        claim: ForegroundTransportClaim(
          activityId: 'denied-foreground',
          bindingDigest: lease.bindingDigest,
          nativeGeneration: 1,
        ),
      ),
      isNull,
    );
  });

  test('expired lease admits exactly one replacement', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    expect(await first.acquire(_lease('expired', now.subtract(const Duration(minutes: 2))), now), isTrue);

    final replacements = [_lease('replacement-a', now), _lease('replacement-b', now)];
    final results = await Future.wait([first.acquire(replacements[0], now), second.acquire(replacements[1], now)]);

    expect(results.where((result) => result), hasLength(1));
  });

  test('renew, release, and callback transitions require exact payload and reject ABA', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('token-a', now);
    expect(await first.acquire(acquired, now), isTrue);

    final renewed = acquired.copyWith(expiresAt: now.add(const Duration(minutes: 2)), activityRevision: 1);
    expect(await first.replaceExact(expected: acquired, replacement: renewed), isTrue);
    expect(
      await second.replaceExact(expected: acquired, replacement: acquired.copyWith(activityRevision: 99)),
      isFalse,
    );
    expect(await second.releaseExact(acquired), isFalse);

    final callback = await first.beginCallback(renewed);
    expect(callback?.callbacksInFlight, 1);
    expect(callback?.activityRevision, 2);
    expect(await second.beginCallback(renewed), isNull);

    final enqueued = await first.markEnqueued(callback!);
    expect(enqueued?.activityRevision, 3);
    final ended = await first.endCallback(enqueued!);
    expect(ended?.callbacksInFlight, 0);
    expect(ended?.activityRevision, 4);
    expect(await first.releaseExact(renewed), isFalse);
    expect(await first.releaseExact(ended!), isTrue);
  });

  test('enqueue claim survives early and duplicate terminal without creating a ghost task', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('reserved-run', now);
    expect(await first.acquire(acquired, now), isTrue);

    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-task');
    final reserved = await first.beginEnqueueForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: claim,
    );
    expect(reserved?.enqueueClaims, {claim});
    expect(reserved?.outstandingClaims, isEmpty);

    final earlyTerminal = await first.consumeTerminalForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: claim,
    );
    expect(earlyTerminal?.enqueueClaims, isEmpty);
    expect(earlyTerminal?.terminalTombstones, {claim});

    final duplicateTerminal = await second.consumeTerminalForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: claim,
    );
    expect(duplicateTerminal, earlyTerminal);

    final confirmed = await first.confirmEnqueueForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: claim,
    );
    expect(confirmed?.terminalTombstones, isEmpty);
    expect(confirmed?.outstandingClaims, isEmpty);

    expect(
      await first.beginCallbackForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: claim,
      ),
      isNull,
    );
    expect(await first.releaseExact(confirmed!), isTrue);
  });

  test('normal terminal removes outstanding claim and releases without a tombstone', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('normal-terminal', now);
    expect(await first.acquire(acquired, now), isTrue);
    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-normal');
    expect(
      await first.beginEnqueueForTask(runToken: acquired.runToken, bindingDigest: acquired.bindingDigest, claim: claim),
      isNotNull,
    );
    expect(
      await first.confirmEnqueueForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: claim,
      ),
      isNotNull,
    );

    final terminal = await first.consumeTerminalForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: claim,
    );

    expect(terminal?.outstandingClaims, isEmpty);
    expect(terminal?.terminalTombstones, isEmpty);
    expect(await first.releaseExact(terminal!), isTrue);
  });

  test('quarantine atomically deduplicates a stale reconciliation and releases its lease', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-stale-task');
    final candidateKey = BackupCandidateKey.fromLocalIdentity(deviceId: 'device-a', localAssetId: 'asset-a').value;
    final acquired = _lease('stale-reconciliation', now).copyWith(reconciliationClaims: {claim});
    expect(await first.acquire(acquired, now), isTrue);

    final quarantined = await first.quarantineReconciliationForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: claim,
      candidateKey: candidateKey,
      code: BackupReconciliationQuarantineCode.definitivelyStale,
    );

    expect(quarantined?.reconciliationClaims, isEmpty);
    expect(await second.readReconciliationQuarantine(), {
      BackupReconciliationQuarantineEntry(
        claim: claim,
        candidateKey: candidateKey,
        bindingDigest: acquired.bindingDigest,
        code: BackupReconciliationQuarantineCode.definitivelyStale,
      ),
    });
    expect(
      await second.quarantineReconciliationForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: claim,
        candidateKey: candidateKey,
        code: BackupReconciliationQuarantineCode.definitivelyStale,
      ),
      isNull,
    );
    expect(await first.releaseExact(quarantined!), isTrue);
  });

  test('quarantine is an atomic per-candidate enqueue gate across lease restart', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    const staleClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-stale');
    const retryClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-retry');
    const otherClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-other');
    final staleKey = BackupCandidateKey.fromLocalIdentity(deviceId: 'device-a', localAssetId: 'asset-a').value;
    final otherKey = BackupCandidateKey.fromLocalIdentity(deviceId: 'device-a', localAssetId: 'asset-b').value;
    final original = _lease('original', now).copyWith(reconciliationClaims: {staleClaim});
    expect(await first.acquire(original, now), isTrue);
    final quarantined = await first.quarantineReconciliationForTask(
      runToken: original.runToken,
      bindingDigest: original.bindingDigest,
      claim: staleClaim,
      candidateKey: staleKey,
      code: BackupReconciliationQuarantineCode.definitivelyStale,
    );
    expect(await first.releaseExact(quarantined!), isTrue);
    final restarted = _lease('restarted', now);
    expect(await second.acquire(restarted, now), isTrue);

    expect(
      await first.beginEnqueueUnlessQuarantined(
        runToken: restarted.runToken,
        bindingDigest: restarted.bindingDigest,
        claim: retryClaim,
        candidateKey: staleKey,
      ),
      isNull,
    );
    final admitted = await second.beginEnqueueUnlessQuarantined(
      runToken: restarted.runToken,
      bindingDigest: restarted.bindingDigest,
      claim: otherClaim,
      candidateKey: otherKey,
    );
    expect(admitted?.enqueueClaims, {otherClaim});
  });

  test('malformed quarantine fails closed for automatic candidate admission', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final lease = _lease('malformed-gate', now);
    expect(await first.acquire(lease, now), isTrue);
    await firstDb.customUpdate(
      'INSERT INTO store_entity (id, string_value, int_value) VALUES (?1, ?2, NULL)',
      variables: [Variable.withInt(StoreKey.backupReconciliationQuarantine.id), Variable.withString('{malformed')],
      updates: {firstDb.storeEntity},
    );

    expect(
      await first.beginEnqueueUnlessQuarantined(
        runToken: lease.runToken,
        bindingDigest: lease.bindingDigest,
        claim: const BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-task'),
        candidateKey: BackupCandidateKey.fromLocalIdentity(deviceId: 'device-a', localAssetId: 'asset-a').value,
      ),
      isNull,
    );
  });

  test('callbacks accept only active task claims and reject unknown claims', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('callback-owner', now);
    expect(await first.acquire(acquired, now), isTrue);

    const unknown = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-unknown');
    expect(
      await first.beginCallbackForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: unknown,
      ),
      isNull,
    );
    expect((await first.read())?.callbacksInFlight, 0);

    const active = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-active-callback');
    expect(
      await first.beginEnqueueForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: active,
      ),
      isNotNull,
    );
    final begun = await first.beginCallbackForTask(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      claim: active,
    );
    expect(begun?.callbackClaims, {active});
    expect(
      await second.beginCallbackForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: active,
      ),
      isNull,
    );
    expect(
      await first.endCallbackForTask(runToken: acquired.runToken, bindingDigest: acquired.bindingDigest, claim: active),
      isNotNull,
    );
  });

  test('expired closing recovery clears the exact orphan snapshot in one CAS transition', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    const taskClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-orphan');
    const foregroundClaim = ForegroundTransportClaim(
      activityId: 'opaque-foreground',
      bindingDigest: 'binding-digest',
      nativeGeneration: 7,
    );
    final expected = _lease('expired-closing', now.subtract(const Duration(minutes: 2))).copyWith(
      state: BackupExecutionState.closing,
      callbacksInFlight: 1,
      outstandingClaims: {taskClaim},
      callbackClaims: {taskClaim},
      foregroundActivityClaims: {foregroundClaim},
    );
    expect(await first.acquire(expected, now), isTrue);

    final recovered = await first.recoverExpiredClosingExact(expected: expected, activeClaims: const {});

    expect(recovered?.callbacksInFlight, 0);
    expect(recovered?.outstandingClaims, isEmpty);
    expect(recovered?.callbackClaims, isEmpty);
    expect(recovered?.foregroundActivityClaims, isEmpty);
    expect(recovered?.activityRevision, expected.activityRevision + 1);
    expect(await second.read(), recovered);
  });

  test('expired closing recovery CAS miss preserves callback activity from another connection', () async {
    final now = DateTime.utc(2026, 9, 2, 13);
    const originalClaim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-original');
    const newClaim = BackupTaskClaim(group: BackupTaskGroup.livePhoto, taskId: 'opaque-new');
    final expected = _lease('expired-closing-race', now.subtract(const Duration(minutes: 2))).copyWith(
      state: BackupExecutionState.closing,
      callbacksInFlight: 1,
      outstandingClaims: {originalClaim},
      callbackClaims: {originalClaim},
    );
    expect(await first.acquire(expected, now), isTrue);
    final raced = expected.copyWith(
      callbacksInFlight: 2,
      outstandingClaims: {originalClaim, newClaim},
      callbackClaims: {originalClaim, newClaim},
      activityRevision: expected.activityRevision + 1,
    );
    expect(await second.replaceExact(expected: expected, replacement: raced), isTrue);

    expect(await first.recoverExpiredClosingExact(expected: expected, activeClaims: const {}), isNull);
    expect(await first.read(), raced);
  });

  test('closing and begin enqueue race across two connections and exactly one wins', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('concurrent-run', now);
    expect(await first.acquire(acquired, now), isTrue);

    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-race');
    final transitions = await Future.wait([
      first.beginClosingForOwner(runToken: acquired.runToken, bindingDigest: acquired.bindingDigest),
      second.beginEnqueueForTask(runToken: acquired.runToken, bindingDigest: acquired.bindingDigest, claim: claim),
    ]);

    expect(transitions.where((transition) => transition != null), hasLength(1));
    final current = await first.read();
    final closingWon = current?.state == BackupExecutionState.closing && current!.enqueueClaims.isEmpty;
    final enqueueWon = current?.state == BackupExecutionState.accepting && current!.enqueueClaims.contains(claim);
    expect(closingWon || enqueueWon, isTrue);
  });

  test('reconcile never drops a live enqueue claim', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('reconcile-run', now);
    expect(await first.acquire(acquired, now), isTrue);
    const enqueue = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-enqueue');
    expect(
      await first.beginEnqueueForTask(
        runToken: acquired.runToken,
        bindingDigest: acquired.bindingDigest,
        claim: enqueue,
      ),
      isNotNull,
    );

    final reconciled = await second.reconcileTaskClaimsForOwner(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      activeClaims: const {},
    );

    expect(reconciled?.enqueueClaims, {enqueue});
  });

  test('active native enqueue claim is normalized to outstanding after a crash', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('crashed-enqueue', now);
    expect(await first.acquire(acquired, now), isTrue);
    const claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-active');
    expect(
      await first.beginEnqueueForTask(runToken: acquired.runToken, bindingDigest: acquired.bindingDigest, claim: claim),
      isNotNull,
    );

    final reconciled = await second.reconcileTaskClaimsForOwner(
      runToken: acquired.runToken,
      bindingDigest: acquired.bindingDigest,
      activeClaims: {claim},
    );

    expect(reconciled?.enqueueClaims, isEmpty);
    expect(reconciled?.outstandingClaims, {claim});
  });

  test('expired takeover racing a foreground activity claim has exactly one winner', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final expired = _lease('expired-owner', now.subtract(const Duration(minutes: 2)));
    expect(await first.acquire(expired, now), isTrue);

    final results = await Future.wait<Object?>([
      first.beginForegroundActivityForOwner(
        runToken: expired.runToken,
        bindingDigest: expired.bindingDigest,
        claim: const ForegroundTransportClaim(
          activityId: 'opaque-transport',
          bindingDigest: 'binding-digest',
          nativeGeneration: 7,
        ),
      ),
      second.acquire(_lease('replacement', now), now),
    ]);

    expect(results.where((result) => result != null && result != false), hasLength(1));
  });

  test('more than eight contending transitions all finish and callback count returns to zero', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    final acquired = _lease('contention-run', now);
    expect(await first.acquire(acquired, now), isTrue);

    await Future.wait(
      List.generate(24, (index) async {
        final repository = index.isEven ? first : second;
        final claim = BackupTaskClaim(group: BackupTaskGroup.primary, taskId: 'opaque-callback-$index');
        expect(
          await repository.beginEnqueueForTask(
            runToken: acquired.runToken,
            bindingDigest: acquired.bindingDigest,
            claim: claim,
          ),
          isNotNull,
        );
        final begun = await repository.beginCallbackForTask(
          runToken: acquired.runToken,
          bindingDigest: acquired.bindingDigest,
          claim: claim,
        );
        expect(begun, isNotNull);
        expect(
          await repository.endCallbackForTask(
            runToken: acquired.runToken,
            bindingDigest: acquired.bindingDigest,
            claim: claim,
          ),
          isNotNull,
        );
      }),
    );

    expect((await first.read())?.callbacksInFlight, 0);
  });

  test('malformed durable payload is atomically recoverable', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    await firstDb.customUpdate(
      'INSERT INTO store_entity (id, string_value, int_value) VALUES (?1, ?2, NULL)',
      variables: [Variable.withInt(StoreKey.backupExecutionLease.id), Variable.withString('{malformed')],
      updates: {firstDb.storeEntity},
    );

    final replacement = _lease('recovered', now);
    expect(await first.acquire(replacement, now), isTrue);
    expect(await second.read(), replacement);
  });

  test('unsupported durable schema is atomically recoverable before expiry', () async {
    final now = DateTime.utc(2026, 8, 11, 12);
    await firstDb.customUpdate(
      'INSERT INTO store_entity (id, string_value, int_value) VALUES (?1, ?2, NULL)',
      variables: [
        Variable.withInt(StoreKey.backupExecutionLease.id),
        Variable.withString(
          '{"schemaVersion":1,"expiryEpochMs":${now.add(const Duration(hours: 1)).millisecondsSinceEpoch}}',
        ),
      ],
      updates: {firstDb.storeEntity},
    );

    final replacement = _lease('schema-recovered', now);
    expect(await first.acquire(replacement, now), isTrue);
    expect(await second.read(), replacement);
  });
}

Future<void> _setBackupEnabled(Drift db, bool enabled) async {
  await db.transaction(() async {
    await db.customUpdate(
      '''
      INSERT INTO store_entity (id, string_value, int_value)
      VALUES (?1, NULL, ?2)
      ON CONFLICT(id) DO UPDATE SET string_value = NULL, int_value = excluded.int_value
      ''',
      variables: [Variable.withInt(StoreKey.enableBackup.id), Variable.withInt(enabled ? 1 : 0)],
      updates: {db.storeEntity},
    );
    final state = DurableBackupEnablementState(
      phase: enabled ? DurableBackupEnablementPhase.enabled : DurableBackupEnablementPhase.disabling,
      generation: 1,
    );
    await db.customUpdate(
      '''
      INSERT INTO store_entity (id, string_value, int_value)
      VALUES (?1, ?2, NULL)
      ON CONFLICT(id) DO UPDATE SET string_value = excluded.string_value, int_value = NULL
      ''',
      variables: [Variable.withInt(StoreKey.backupEnablementState.id), Variable.withString(state.toJson())],
      updates: {db.storeEntity},
    );
  });
}

BackupExecutionLease _lease(String token, DateTime now) => BackupExecutionLease(
  mode: BackupExecutionMode.foreground,
  runToken: token,
  bindingDigest: 'binding-digest',
  expiresAt: now.add(const Duration(minutes: 1)),
  activityRevision: 0,
  callbacksInFlight: 0,
);
