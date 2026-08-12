import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

final class ForegroundTransportFenceAdapter implements ForegroundTransportFencePort {
  const ForegroundTransportFenceAdapter(this._bindings);

  final BackupRunBindingSourcePort _bindings;

  @override
  Future<bool> fenceAndDrain(ForegroundTransportClaim claim) async {
    final binding = _bindings.capture();
    if (binding == null ||
        binding.digest != claim.bindingDigest ||
        binding.nativeGeneration != claim.nativeGeneration) {
      return false;
    }
    return NetworkRepository.fenceAndDrainCurrentTransport(
      canonicalOrigin: binding.canonicalOrigin,
      sessionEpoch: binding.sessionEpoch,
      nativeGeneration: binding.nativeGeneration,
    );
  }
}
