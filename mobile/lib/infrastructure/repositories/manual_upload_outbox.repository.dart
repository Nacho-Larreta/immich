import 'package:drift/drift.dart';
import 'package:immich_mobile/domain/interfaces/manual_upload_outbox.interface.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent_validation.dart';
import 'package:immich_mobile/infrastructure/entities/manual_upload_intent.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_intent_codec.dart';

final class DriftManualUploadOutbox implements ManualUploadOutbox {
  const DriftManualUploadOutbox(this._database);

  final ManualUploadDatabase _database;

  @override
  Stream<void> get changes =>
      _database.tableUpdates(TableUpdateQuery.onTable(_database.manualUploadIntentEntity)).map((_) {});

  @override
  Future<List<ManualUploadIntent>> submit(List<ManualUploadSelection> selections) async {
    final intents = selections.map(ManualUploadIntent.fromSelection).toList(growable: false);
    for (final intent in intents) {
      validateManualUploadIntent(intent);
    }
    return _database.transaction(() async {
      final accepted = <ManualUploadIntent>[];
      for (final intent in intents) {
        final existing = await _findActive(intent);
        if (existing != null) {
          accepted.add(existing);
        } else {
          await _database.into(_database.manualUploadIntentEntity).insert(_row(intent));
          accepted.add(intent);
        }
      }
      return accepted;
    });
  }

  Future<ManualUploadIntent?> _findActive(ManualUploadIntent intent) async {
    final query = _database.select(_database.manualUploadIntentEntity)
      ..where(
        (row) =>
            row.serverUrl.equals(intent.destination.serverUrl) &
            row.userId.equals(intent.destination.userId) &
            row.deviceId.equals(intent.deviceId) &
            row.localAssetId.equals(intent.localAssetId) &
            row.active.equals(true),
      );
    final row = await query.getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  @override
  Future<ManualUploadIntent?> read(String intentId) async {
    final query = _database.select(_database.manualUploadIntentEntity)..where((row) => row.id.equals(intentId));
    final row = await query.getSingleOrNull();
    return row == null ? null : _decode(row);
  }

  @override
  Future<List<ManualUploadIntent>> listActive(
    ManualUploadDestination destination, {
    int limit = 100,
    String? afterId,
  }) async {
    if (limit <= 0 || limit > 1000) throw ArgumentError.value(limit, 'limit', 'Must be between 1 and 1000');
    final query = _database.select(_database.manualUploadIntentEntity)
      ..where(
        (row) =>
            row.serverUrl.equals(destination.serverUrl) &
            row.userId.equals(destination.userId) &
            row.active.equals(true),
      );
    if (afterId != null) query.where((row) => row.id.isBiggerThanValue(afterId));
    query
      ..orderBy([(row) => OrderingTerm.asc(row.id)])
      ..limit(limit);
    return (await query.get()).map(_decode).toList(growable: false);
  }

  @override
  Future<bool> compareAndSet(ManualUploadIntent expected, ManualUploadIntent next) async {
    validateManualUploadTransition(expected, next);
    final query = _database.update(_database.manualUploadIntentEntity)
      ..where(
        (row) =>
            row.id.equals(expected.id) &
            row.version.equals(expected.version) &
            row.payload.equals(ManualUploadIntentCodec.encode(expected)),
      );
    return await query.write(_row(next)) == 1;
  }

  ManualUploadIntentEntityCompanion _row(ManualUploadIntent intent) => ManualUploadIntentEntityCompanion.insert(
    id: intent.id,
    serverUrl: intent.destination.serverUrl,
    userId: intent.destination.userId,
    deviceId: intent.deviceId,
    localAssetId: intent.localAssetId,
    version: intent.version,
    active: intent.isActive,
    payload: ManualUploadIntentCodec.encode(intent),
  );

  ManualUploadIntent _decode(ManualUploadIntentEntityData row) {
    final intent = ManualUploadIntentCodec.decode(row.payload);
    if (intent.id != row.id ||
        intent.destination.serverUrl != row.serverUrl ||
        intent.destination.userId != row.userId ||
        intent.deviceId != row.deviceId ||
        intent.localAssetId != row.localAssetId ||
        intent.version != row.version ||
        intent.isActive != row.active) {
      throw const FormatException('Manual upload index and payload disagree');
    }
    return intent;
  }
}
