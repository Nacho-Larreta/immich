import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

typedef ForegroundTransportIdentityReader = Future<ForegroundTransportIdentity?> Function();
typedef ForegroundTransportClaimsRetirer =
    Future<ForegroundTransportRetirement> Function(Set<ForegroundTransportClaim> claims, Duration timeout);
typedef ForegroundTransportIdentityValidator = bool Function(ForegroundTransportIdentity identity);

final class ForegroundTransportFenceAdapter implements ForegroundTransportFencePort {
  ForegroundTransportFenceAdapter(
    this._bindings, {
    ForegroundTransportIdentityReader? readIdentity,
    ForegroundTransportClaimsRetirer? retireClaims,
    ForegroundTransportIdentityValidator? validateIdentity,
  }) : _readIdentity = readIdentity ?? NetworkRepository.captureForegroundTransportIdentity,
       _retireClaims = retireClaims ?? NetworkRepository.retireForegroundTransportClaims,
       _validateIdentity = validateIdentity ?? NetworkRepository.isForegroundTransportIdentityCurrent;

  final BackupRunBindingSourcePort _bindings;
  final ForegroundTransportIdentityReader _readIdentity;
  final ForegroundTransportClaimsRetirer _retireClaims;
  final ForegroundTransportIdentityValidator _validateIdentity;

  @override
  Future<ForegroundTransportIdentity?> captureIdentity() async {
    final binding = _bindings.capture();
    if (binding == null) return null;
    final identity = await _readIdentity();
    return identity?.generation == binding.nativeGeneration && _bindings.isCurrent(binding) ? identity : null;
  }

  @override
  bool isIdentityCurrent(ForegroundTransportIdentity identity, {required String bindingDigest}) {
    final binding = _bindings.capture();
    return binding != null &&
        binding.digest == bindingDigest &&
        binding.nativeGeneration == identity.generation &&
        _bindings.isCurrent(binding) &&
        _validateIdentity(identity);
  }

  @override
  Future<ForegroundTransportRetirement> retireClaims(
    Set<ForegroundTransportClaim> claims, {
    required Duration timeout,
  }) {
    if (claims.isEmpty) return Future.value(ForegroundTransportRetirement.retired);
    return _retireClaims(Set.unmodifiable(claims), timeout);
  }
}
