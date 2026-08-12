import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';

abstract interface class EagerBackupOperationsPort {
  Future<BackupWorkload> readWorkload();

  Future<void> synchronizeLocal(EagerBackupCancellation cancellation);

  Future<void> hashAssets(EagerBackupCancellation cancellation);

  Future<BackupRunBinding?> captureBinding();

  Future<EagerBackupUploadOutcome> upload(BackupRunBinding binding, EagerBackupCancellation cancellation);
}

abstract interface class EagerBackupWorkloadMonitorPort {
  Stream<BackupWorkload> watch(String userId);
}

abstract interface class EagerBackupPhotoObserverPort {
  Future<void> start();

  Future<void> dispose();
}

abstract interface class EagerBackupScheduledRetry {
  void cancel();
}

abstract interface class EagerBackupRetryScheduler {
  EagerBackupScheduledRetry schedule(Duration delay, void Function() callback);
}
