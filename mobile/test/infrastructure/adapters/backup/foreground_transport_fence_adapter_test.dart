import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/foreground_transport_fence_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

void main() {
  test('retires a persisted legacy claim after the authenticated session was replaced', () async {
    final previous = _binding(sessionEpoch: 3, nativeGeneration: 7);
    final current = _binding(sessionEpoch: 4, nativeGeneration: 9);
    final claim = ForegroundTransportClaim.legacy(
      activityId: 'persisted-session-a',
      bindingDigest: previous.digest,
      nativeGeneration: previous.nativeGeneration,
    );
    Set<ForegroundTransportClaim>? retiredClaims;
    final adapter = ForegroundTransportFenceAdapter(
      _BindingSource(current),
      retireClaims: (claims, _) async {
        retiredClaims = claims;
        return ForegroundTransportRetirement.retired;
      },
    );

    final retired = await adapter.retireClaims({claim}, timeout: const Duration(seconds: 1));

    expect(retired, ForegroundTransportRetirement.retired);
    expect(retiredClaims, {claim});
  });

  test('issues a claim identity only when native authority matches the current binding generation', () async {
    const identity = ForegroundTransportIdentity(incarnation: 'root-process', generation: 7);
    final matching = ForegroundTransportFenceAdapter(_BindingSource(_binding()), readIdentity: () async => identity);
    final stale = ForegroundTransportFenceAdapter(
      _BindingSource(_binding(nativeGeneration: 8)),
      readIdentity: () async => identity,
    );

    expect(await matching.captureIdentity(), identity);
    expect(await stale.captureIdentity(), isNull);
  });

  test('rejects an identity when the binding changes while native authority is awaited', () async {
    const identity = ForegroundTransportIdentity(incarnation: 'root-process', generation: 7);
    final source = _MutableBindingSource(_binding());
    final adapter = ForegroundTransportFenceAdapter(
      source,
      readIdentity: () async {
        source.binding = _binding(sessionEpoch: 4, nativeGeneration: 8);
        return identity;
      },
    );

    expect(await adapter.captureIdentity(), isNull);
  });

  test('preserves a non-positive native retirement result without treating mismatch as success', () async {
    final adapter = ForegroundTransportFenceAdapter(
      _BindingSource(_binding()),
      retireClaims: (_, _) async => ForegroundTransportRetirement.temporarilyUnproven,
    );
    final claim = ForegroundTransportClaim.current(
      activityId: 'aba-claim',
      bindingDigest: 'different-session',
      nativeGeneration: 7,
      transportIncarnation: 'previous-process',
    );

    expect(
      await adapter.retireClaims({claim}, timeout: const Duration(seconds: 1)),
      ForegroundTransportRetirement.temporarilyUnproven,
    );
  });

  test('attached worker cannot issue or retire foreground transport claims', () async {
    NetworkRepository.setContextRoleForTest(NetworkContextRole.attachedWorker);
    final claim = ForegroundTransportClaim.current(
      activityId: 'attached-worker-claim',
      bindingDigest: 'binding',
      nativeGeneration: 7,
      transportIncarnation: 'attached-process',
    );

    try {
      expect(await NetworkRepository.captureForegroundTransportIdentity(), isNull);
      expect(
        await NetworkRepository.retireForegroundTransportClaims({claim}, const Duration(seconds: 1)),
        ForegroundTransportRetirement.unsupported,
      );
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

final class _MutableBindingSource implements BackupRunBindingSourcePort {
  _MutableBindingSource(this.binding);

  BackupRunBinding binding;

  @override
  BackupRunBinding capture() => binding;

  @override
  bool isCurrent(BackupRunBinding binding) => binding == this.binding;
}
