import 'package:immich_mobile/domain/models/server_access.model.dart';

final class RemoteMutationGuard {
  const RemoteMutationGuard(this._readPolicy);

  final ServerAccessPolicy Function() _readPolicy;

  void requireAllowed() {
    if (!_readPolicy().allows(ServerCapability.remoteMutation)) {
      throw StateError('Server mutations require an online authenticated session');
    }
  }
}
