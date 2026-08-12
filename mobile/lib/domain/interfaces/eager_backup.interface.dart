import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';

abstract interface class EagerBackupOperationsPort {
  Future<BackupWorkload> readWorkload();

  Future<void> synchronizeLocal(EagerBackupCancellation cancellation);

  Future<void> hashAssets(EagerBackupCancellation cancellation);

  Future<BackupRunBinding?> captureBinding();

  Future<void> upload(BackupRunBinding binding, EagerBackupCancellation cancellation);
}

abstract interface class EagerBackupScheduledRetry {
  void cancel();
}

abstract interface class EagerBackupRetryScheduler {
  EagerBackupScheduledRetry schedule(Duration delay, void Function() callback);
}
