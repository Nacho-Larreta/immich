import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/foreground_transport_fence_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

final backupExecutionLeaseProvider = Provider<BackupExecutionLeasePort>(
  (ref) => DriftBackupExecutionLeaseRepository(ref.watch(driftProvider)),
);

final backupExecutionArbiterProvider = Provider<BackupExecutionArbiter>(
  (ref) => BackupExecutionArbiter(
    leases: ref.watch(backupExecutionLeaseProvider),
    tasks: ref.watch(uploadRepositoryProvider),
    foregroundFence: ForegroundTransportFenceAdapter(ref.watch(backupRunBindingSourceProvider)),
  ),
);
