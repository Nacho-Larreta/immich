import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/services/backup_callback_fence.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/foreground_transport_fence_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_execution_lease.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

final backupExecutionLeaseProvider = Provider<BackupExecutionLeasePort>(
  (ref) => DriftBackupExecutionLeaseRepository(ref.watch(driftProvider)),
);

final backupCallbackFenceProvider = Provider<BackupCallbackFencePort>((ref) => BackupCallbackFence());

final backupExecutionContextRoleProvider = Provider<NetworkContextRole>(
  (_) => NetworkRepository.isAttachedWorker ? NetworkContextRole.attachedWorker : NetworkContextRole.rootWriter,
);

final backupCallbackRecoveryCapabilityProvider = Provider<BackupCallbackFencePort?>((ref) {
  final isRootIOS =
      CurrentPlatform.isIOS && ref.watch(backupExecutionContextRoleProvider) == NetworkContextRole.rootWriter;
  return isRootIOS ? ref.watch(backupCallbackFenceProvider) : null;
});

final backupExecutionArbiterProvider = Provider<BackupExecutionArbiter>(
  (ref) => BackupExecutionArbiter(
    leases: ref.watch(backupExecutionLeaseProvider),
    tasks: ref.watch(uploadRepositoryProvider),
    foregroundFence: ForegroundTransportFenceAdapter(ref.watch(backupRunBindingSourceProvider)),
    callbackFence: ref.watch(backupCallbackRecoveryCapabilityProvider),
  ),
);
