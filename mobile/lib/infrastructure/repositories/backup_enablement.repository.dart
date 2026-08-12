import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';

final class DriftBackupEnablementRepository {
  const DriftBackupEnablementRepository(this._db);

  final Drift _db;

  Future<DurableBackupEnablementState?> read() async {
    final row = await _db
        .customSelect(
          'SELECT string_value FROM store_entity WHERE id = ?1',
          variables: [Variable.withInt(StoreKey.backupEnablementState.id)],
        )
        .getSingleOrNull();
    return DurableBackupEnablementState.tryParse(row?.read<String?>('string_value'));
  }

  Future<DurableBackupEnablementState> initialize(bool legacyEnabled) {
    return _db.transaction(() async {
      final current = await read();
      if (current != null) return current;
      final initial = DurableBackupEnablementState(
        phase: legacyEnabled ? DurableBackupEnablementPhase.enabled : DurableBackupEnablementPhase.disabling,
        generation: legacyEnabled ? 0 : 1,
      );
      await _writeEnabled(legacyEnabled);
      await _writeState(initial);
      return initial;
    });
  }

  Future<bool> admitsBackupWork() async => (await read())?.phase == DurableBackupEnablementPhase.enabled;

  Future<DurableBackupEnablementState> beginDisable() async {
    final rows = await _db
        .customSelect(
          '''
      INSERT INTO store_entity (id, string_value, int_value)
      VALUES
        (?1, NULL, 0),
        (
          ?2,
          json_object(
            'schemaVersion', 1,
            'phase', 'disabling',
            'generation', COALESCE(
              (
                SELECT CAST(json_extract(string_value, '\$.generation') AS INTEGER)
                FROM store_entity
                WHERE id = ?2 AND json_valid(string_value)
              ),
              0
            ) + 1
          ),
          NULL
        )
      ON CONFLICT(id) DO UPDATE SET
        string_value = excluded.string_value,
        int_value = excluded.int_value
      RETURNING id, string_value
      ''',
          variables: [Variable.withInt(StoreKey.enableBackup.id), Variable.withInt(StoreKey.backupEnablementState.id)],
          readsFrom: {_db.storeEntity},
        )
        .get();
    final stateRow = rows.where((row) => row.read<int>('id') == StoreKey.backupEnablementState.id).single;
    final disabling = DurableBackupEnablementState.tryParse(stateRow.read<String?>('string_value'));
    if (disabling == null || disabling.phase != DurableBackupEnablementPhase.disabling) {
      throw const FormatException('Invalid backup enablement transition');
    }
    return disabling;
  }

  Future<bool> completeDrain(DurableBackupEnablementState disabling) {
    return _transitionExact(disabling, disabling.transitionTo(DurableBackupEnablementPhase.disabledDrained));
  }

  Future<bool> failDrain(DurableBackupEnablementState disabling) {
    return _transitionExact(disabling, disabling.transitionTo(DurableBackupEnablementPhase.drainFailed));
  }

  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained) {
    if (disabledDrained.phase != DurableBackupEnablementPhase.disabledDrained) return Future.value(false);
    final enabled = disabledDrained.transitionTo(DurableBackupEnablementPhase.enabled, advance: true);
    return _db
        .customUpdate(
          '''
          INSERT INTO store_entity (id, string_value, int_value)
          SELECT ?1, NULL, 1
          WHERE EXISTS (
            SELECT 1 FROM store_entity
            WHERE id = ?2 AND string_value = ?3
          )
          AND COALESCE((SELECT int_value FROM store_entity WHERE id = ?1), 0) = 0
          UNION ALL
          SELECT ?2, ?4, NULL
          WHERE EXISTS (
            SELECT 1 FROM store_entity
            WHERE id = ?2 AND string_value = ?3
          )
          AND COALESCE((SELECT int_value FROM store_entity WHERE id = ?1), 0) = 0
          ON CONFLICT(id) DO UPDATE SET
            string_value = excluded.string_value,
            int_value = excluded.int_value
          ''',
          variables: [
            Variable.withInt(StoreKey.enableBackup.id),
            Variable.withInt(StoreKey.backupEnablementState.id),
            Variable.withString(disabledDrained.toJson()),
            Variable.withString(enabled.toJson()),
          ],
          updates: {_db.storeEntity},
        )
        .then((affected) => affected == 2);
  }

  Future<bool> _transitionExact(DurableBackupEnablementState expected, DurableBackupEnablementState replacement) async {
    final affected = await _db.customUpdate(
      '''
      UPDATE store_entity
      SET string_value = ?1, int_value = NULL
      WHERE id = ?2
        AND string_value = ?3
        AND COALESCE((SELECT int_value FROM store_entity WHERE id = ?4), 0) = 0
      ''',
      variables: [
        Variable.withString(replacement.toJson()),
        Variable.withInt(StoreKey.backupEnablementState.id),
        Variable.withString(expected.toJson()),
        Variable.withInt(StoreKey.enableBackup.id),
      ],
      updates: {_db.storeEntity},
    );
    return affected == 1;
  }

  Future<void> _writeEnabled(bool enabled) async {
    await _db.customUpdate(
      '''
      INSERT INTO store_entity (id, string_value, int_value)
      VALUES (?1, NULL, ?2)
      ON CONFLICT(id) DO UPDATE SET string_value = NULL, int_value = excluded.int_value
      ''',
      variables: [Variable.withInt(StoreKey.enableBackup.id), Variable.withInt(enabled ? 1 : 0)],
      updates: {_db.storeEntity},
    );
  }

  Future<void> _writeState(DurableBackupEnablementState state) async {
    await _db.customUpdate(
      '''
      INSERT INTO store_entity (id, string_value, int_value)
      VALUES (?1, ?2, NULL)
      ON CONFLICT(id) DO UPDATE SET string_value = excluded.string_value, int_value = NULL
      ''',
      variables: [Variable.withInt(StoreKey.backupEnablementState.id), Variable.withString(state.toJson())],
      updates: {_db.storeEntity},
    );
  }
}
