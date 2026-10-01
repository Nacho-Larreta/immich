import 'package:drift/drift.dart';
import 'package:drift_flutter/drift_flutter.dart';
import 'package:immich_mobile/infrastructure/entities/manual_upload_intent.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/manual_upload_db.repository.drift.dart';
import 'package:path_provider/path_provider.dart';

@DriftDatabase(tables: [ManualUploadIntentEntity])
class ManualUploadDatabase extends $ManualUploadDatabase {
  ManualUploadDatabase([QueryExecutor? executor])
    : super(
        executor ??
            driftDatabase(
              name: 'immich_manual_uploads',
              native: const DriftNativeOptions(databaseDirectory: getApplicationSupportDirectory),
            ),
      );

  @override
  int get schemaVersion => 1;

  @override
  MigrationStrategy get migration => MigrationStrategy(
    onUpgrade: (_, from, to) async => throw UnsupportedError('Unsupported manual upload schema: $from -> $to'),
    beforeOpen: (_) async {
      await customStatement('PRAGMA journal_mode = WAL');
      await customStatement('PRAGMA synchronous = FULL');
      await customStatement('PRAGMA busy_timeout = 5000');
    },
  );
}
