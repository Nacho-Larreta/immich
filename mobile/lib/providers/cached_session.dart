import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';

final class CachedSession {
  CachedSession({required this.accessToken, required this.apiEndpoint, required this.user, this.deviceId});

  final String accessToken;
  final Uri apiEndpoint;
  final UserDto user;
  final String? deviceId;
}

abstract interface class CachedSessionReader {
  CachedSession? read();
}

final class StoreCachedSessionReader implements CachedSessionReader {
  StoreCachedSessionReader(this._store, this._userService);

  final StoreService _store;
  final UserService _userService;

  @override
  CachedSession? read() {
    final accessToken = _store.tryGet(StoreKey.accessToken);
    final endpointValue = _store.tryGet(StoreKey.serverEndpoint);
    final deviceId = _store.tryGet(StoreKey.deviceId);
    final user = _userService.tryGetMyUser();
    final apiEndpoint = endpointValue == null ? null : Uri.tryParse(endpointValue);

    if (accessToken == null || accessToken.isEmpty || apiEndpoint == null || user == null) {
      return null;
    }
    try {
      validateHttpEndpoint(apiEndpoint, 'serverEndpoint');
    } on ArgumentError {
      return null;
    }

    return CachedSession(accessToken: accessToken, apiEndpoint: apiEndpoint, user: user, deviceId: deviceId);
  }
}
