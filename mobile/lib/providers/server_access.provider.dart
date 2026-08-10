import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/services/remote_mutation_guard.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';

final serverAccessProvider = Provider<ServerAccessPolicy>((ref) {
  final authentication = ref.watch(remoteAuthenticationPhaseProvider);
  final reachability = ref.watch(serverReachabilityStateProvider.select((state) => state.phase));
  return serverAccessPolicy(authentication, reachability);
});

final remoteMutationGuardProvider = Provider<RemoteMutationGuard>(
  (ref) => RemoteMutationGuard(() => ref.read(serverAccessProvider)),
);
