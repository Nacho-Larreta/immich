import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

void main() {
  for (final reachability in ReachabilityPhase.values) {
    test('unconfigured wins over ${reachability.name}', () {
      final access = serverAccessPolicy(RemoteAuthenticationPhase.unconfigured, reachability);
      expect(access.mode, ServerAccessMode.unconfigured);
      expect(access.capabilities, isEmpty);
    });

    test('reauthentication wins over ${reachability.name}', () {
      final access = serverAccessPolicy(RemoteAuthenticationPhase.reauthenticationRequired, reachability);
      expect(access.mode, ServerAccessMode.reauthenticationRequired);
      expect(access.capabilities, {ServerCapability.cachedRead});
    });
  }

  test('authenticated reachability maps exhaustively to capabilities', () {
    expect(
      ReachabilityPhase.values.map((phase) => serverAccessPolicy(RemoteAuthenticationPhase.authenticated, phase)),
      [
        const ServerAccessPolicy.probing(),
        const ServerAccessPolicy.probing(),
        const ServerAccessPolicy.offline(),
        const ServerAccessPolicy.online(),
        const ServerAccessPolicy.offline(),
        const ServerAccessPolicy.offline(),
      ],
    );
  });
}
