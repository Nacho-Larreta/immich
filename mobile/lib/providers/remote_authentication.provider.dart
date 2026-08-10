import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';

enum RemoteAuthenticationPhase { unconfigured, authenticated, reauthenticationRequired }

final remoteAuthenticationPhaseProvider = StateProvider<RemoteAuthenticationPhase>((ref) {
  final endpoint = Store.tryGet(StoreKey.serverEndpoint);
  return remoteAuthenticationPhaseForStoredSession(endpoint: endpoint);
});

RemoteAuthenticationPhase remoteAuthenticationPhaseForStoredSession({required String? endpoint}) =>
    endpoint == null || endpoint.isEmpty
    ? RemoteAuthenticationPhase.unconfigured
    : RemoteAuthenticationPhase.reauthenticationRequired;
