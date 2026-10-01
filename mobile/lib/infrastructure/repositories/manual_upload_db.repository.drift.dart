// dart format width=80
// ignore_for_file: type=lint
import 'package:drift/drift.dart' as i0;
import 'package:immich_mobile/infrastructure/entities/manual_upload_intent.entity.drift.dart'
    as i1;

abstract class $ManualUploadDatabase extends i0.GeneratedDatabase {
  $ManualUploadDatabase(i0.QueryExecutor e) : super(e);
  $ManualUploadDatabaseManager get managers =>
      $ManualUploadDatabaseManager(this);
  late final i1.$ManualUploadIntentEntityTable manualUploadIntentEntity = i1
      .$ManualUploadIntentEntityTable(this);
  @override
  Iterable<i0.TableInfo<i0.Table, Object?>> get allTables =>
      allSchemaEntities.whereType<i0.TableInfo<i0.Table, Object?>>();
  @override
  List<i0.DatabaseSchemaEntity> get allSchemaEntities => [
    manualUploadIntentEntity,
    i1.manualUploadActiveAsset,
    i1.manualUploadActiveDestination,
  ];
  @override
  i0.DriftDatabaseOptions get options =>
      const i0.DriftDatabaseOptions(storeDateTimeAsText: true);
}

class $ManualUploadDatabaseManager {
  final $ManualUploadDatabase _db;
  $ManualUploadDatabaseManager(this._db);
  i1.$$ManualUploadIntentEntityTableTableManager get manualUploadIntentEntity =>
      i1.$$ManualUploadIntentEntityTableTableManager(
        _db,
        _db.manualUploadIntentEntity,
      );
}
