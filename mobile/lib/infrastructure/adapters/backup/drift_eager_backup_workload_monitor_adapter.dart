import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';

final class DriftEagerBackupWorkloadMonitorAdapter implements EagerBackupWorkloadMonitorPort {
  const DriftEagerBackupWorkloadMonitorAdapter(this._backups);

  final DriftBackupRepository _backups;

  @override
  Stream<BackupWorkload> watch(String userId) => _backups
      .watchAllCounts(userId)
      .map((counts) => BackupWorkload(total: counts.total, remainder: counts.remainder, processing: counts.processing));
}
