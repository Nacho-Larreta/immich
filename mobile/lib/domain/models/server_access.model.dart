import 'package:immich_mobile/domain/models/server_reachability.model.dart';

enum RemoteAuthenticationPhase { unconfigured, authenticated, reauthenticationRequired }

enum ServerAccessMode { unconfigured, reauthenticationRequired, probing, offline, online }

enum ServerCapability { cachedRead, remoteRead, remoteMutation }

final class ServerAccessPolicy {
  const ServerAccessPolicy._(this.mode, this.capabilities);

  const ServerAccessPolicy.unconfigured() : this._(ServerAccessMode.unconfigured, const {});

  const ServerAccessPolicy.reauthenticationRequired()
    : this._(ServerAccessMode.reauthenticationRequired, const {ServerCapability.cachedRead});

  const ServerAccessPolicy.probing() : this._(ServerAccessMode.probing, const {ServerCapability.cachedRead});

  const ServerAccessPolicy.offline() : this._(ServerAccessMode.offline, const {ServerCapability.cachedRead});

  const ServerAccessPolicy.online()
    : this._(ServerAccessMode.online, const {
        ServerCapability.cachedRead,
        ServerCapability.remoteRead,
        ServerCapability.remoteMutation,
      });

  final ServerAccessMode mode;
  final Set<ServerCapability> capabilities;

  bool allows(ServerCapability capability) => capabilities.contains(capability);

  @override
  bool operator ==(Object other) => other is ServerAccessPolicy && other.mode == mode;

  @override
  int get hashCode => mode.hashCode;
}

ServerAccessPolicy serverAccessPolicy(RemoteAuthenticationPhase authentication, ReachabilityPhase reachability) {
  return switch (authentication) {
    RemoteAuthenticationPhase.unconfigured => const ServerAccessPolicy.unconfigured(),
    RemoteAuthenticationPhase.reauthenticationRequired => const ServerAccessPolicy.reauthenticationRequired(),
    RemoteAuthenticationPhase.authenticated => switch (reachability) {
      ReachabilityPhase.unknown || ReachabilityPhase.probing => const ServerAccessPolicy.probing(),
      ReachabilityPhase.offline ||
      ReachabilityPhase.paused ||
      ReachabilityPhase.disposed => const ServerAccessPolicy.offline(),
      ReachabilityPhase.online => const ServerAccessPolicy.online(),
    },
  };
}
