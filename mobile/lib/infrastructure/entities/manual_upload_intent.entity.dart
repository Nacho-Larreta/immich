import 'package:drift/drift.dart';

@TableIndex.sql(
  'CREATE UNIQUE INDEX manual_upload_active_asset ON manual_upload_intents (server_url, user_id, device_id, local_asset_id) WHERE active = 1',
)
@TableIndex.sql(
  'CREATE INDEX manual_upload_active_destination ON manual_upload_intents (server_url, user_id, active, id)',
)
class ManualUploadIntentEntity extends Table {
  const ManualUploadIntentEntity();

  @override
  String get tableName => 'manual_upload_intents';

  TextColumn get id => text()();
  TextColumn get serverUrl => text()();
  TextColumn get userId => text()();
  TextColumn get deviceId => text()();
  TextColumn get localAssetId => text()();
  IntColumn get version => integer()();
  BoolColumn get active => boolean()();
  TextColumn get payload => text()();

  @override
  Set<Column> get primaryKey => {id};
}
