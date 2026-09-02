import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/foreground_transport_fence_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

void main() {
  test('rejects session, endpoint, and native-generation mutations before root transport fencing', () async {
    final original = _binding();
    final originalClaim = ForegroundTransportClaim(
      activityId: 'foreground-activity',
      bindingDigest: original.digest,
      nativeGeneration: original.nativeGeneration,
    );
    final changedNative = _binding(nativeGeneration: original.nativeGeneration + 1);
    final cases = [
      (binding: _binding(sessionEpoch: original.sessionEpoch + 1), claim: originalClaim),
      (binding: _binding(host: 'other.example'), claim: originalClaim),
      (
        binding: changedNative,
        claim: ForegroundTransportClaim(
          activityId: 'foreground-activity',
          bindingDigest: changedNative.digest,
          nativeGeneration: original.nativeGeneration,
        ),
      ),
    ];
    NetworkRepository.setContextRoleForTest(NetworkContextRole.attachedWorker);

    try {
      for (final testCase in cases) {
        final adapter = ForegroundTransportFenceAdapter(_BindingSource(testCase.binding));
        expect(await adapter.fenceAndDrain(testCase.claim), isFalse);
      }
    } finally {
      NetworkRepository.setContextRoleForTest(NetworkContextRole.rootWriter);
    }
  });
}

BackupRunBinding _binding({int sessionEpoch = 3, int nativeGeneration = 7, String host = 'photos.example'}) {
  return BackupRunBinding(
    userId: 'user-a',
    sessionEpoch: sessionEpoch,
    probeGeneration: 5,
    nativeGeneration: nativeGeneration,
    apiEndpoint: Uri.parse('https://$host/api'),
    canonicalOrigin: Uri.parse('https://$host'),
    schemePolicy: EndpointSchemePolicy.httpsOnly,
    transportEpoch: 11,
    transportRevision: 13,
    localLeaseRevision: 17,
  );
}

final class _BindingSource implements BackupRunBindingSourcePort {
  const _BindingSource(this.binding);

  final BackupRunBinding binding;

  @override
  BackupRunBinding capture() => binding;

  @override
  bool isCurrent(BackupRunBinding binding) => binding == this.binding;
}
