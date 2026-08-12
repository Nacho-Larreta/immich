import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/models/auth/auxilary_endpoint.model.dart';
import 'package:immich_mobile/models/auth/login_response.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/repositories/auth.repository.dart';
import 'package:immich_mobile/repositories/auth_api.repository.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/network.service.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final authServiceProvider = Provider(
  (ref) => AuthService(
    ref.watch(authApiRepositoryProvider),
    ref.watch(authRepositoryProvider),
    ref.watch(apiServiceProvider),
    ref.watch(networkServiceProvider),
    ref.watch(backgroundSyncProvider),
  ),
);

class AuthService {
  final AuthApiRepository _authApiRepository;
  final AuthRepository _authRepository;
  final ApiService _apiService;
  final NetworkService _networkService;
  final BackgroundSyncManager _backgroundSyncManager;
  final AuthenticationPersistence _authenticationPersistence;
  final _log = Logger("AuthService");

  AuthService(
    this._authApiRepository,
    this._authRepository,
    this._apiService,
    this._networkService,
    this._backgroundSyncManager, {
    AuthenticationPersistence authenticationPersistence = const StoreAuthenticationPersistence(),
  }) : _authenticationPersistence = authenticationPersistence;

  Future<bool> validateAuxilaryServerUrl(String url) async {
    bool isValid = false;

    try {
      final urls = ApiService.getServerUrls();
      urls.add(url);
      await NetworkRepository.setHeaders(ApiService.getRequestHeaders(), urls);
      final uri = Uri.parse('$url/users/me');
      final response = await NetworkRepository.client.get(uri);
      if (response.statusCode == 200) {
        isValid = true;
      }
    } catch (error) {
      _log.severe("Error validating auxiliary endpoint", error);
    }

    return isValid;
  }

  Future<LoginResponse> login(String email, String password) {
    return _authApiRepository.login(email, password);
  }

  Future<void> invalidateRemoteSession() async {
    try {
      await _authApiRepository.logout();
    } catch (error, stackTrace) {
      _log.severe("Error logging out", error, stackTrace);
    }
  }

  Future<void> clearRemoteAuthentication() async {
    await _persistSessionTombstone();
    await _authenticationPersistence.delete(StoreKey.accessToken);
    await _authenticationPersistence.delete(StoreKey.assetETag);
  }

  Future<void> forgetServer() async {
    await _persistSessionTombstone();
    await _backgroundSyncManager.cancel();
    for (final key in [
      StoreKey.currentUser,
      StoreKey.accessToken,
      StoreKey.assetETag,
      StoreKey.customHeaders,
      StoreKey.autoEndpointSwitching,
      StoreKey.preferredWifiName,
      StoreKey.localEndpoint,
      StoreKey.externalEndpointList,
      StoreKey.serverUrl,
      StoreKey.serverEndpoint,
      StoreKey.serverEndpointSchemePolicy,
    ]) {
      await _authenticationPersistence.delete(key);
    }
    await _authRepository.clearLocalData();
  }

  Future<void> _persistSessionTombstone() async {
    try {
      await _authenticationPersistence.markSessionNotReady();
    } catch (error, stackTrace) {
      Error.throwWithStackTrace(AuthenticatedSessionTombstoneWriteFailure(error), stackTrace);
    }
  }

  Future<void> changePassword(String newPassword) {
    try {
      return _authApiRepository.changePassword(newPassword);
    } catch (error, stackTrace) {
      _log.severe("Error changing password", error, stackTrace);
      rethrow;
    }
  }

  Future<String?> setOpenApiServiceEndpoint() async {
    final enable = _authRepository.getEndpointSwitchingFeature();
    if (!enable) {
      return null;
    }

    final wifiName = await _networkService.getWifiName();
    final savedWifiName = _authRepository.getPreferredWifiName();
    String? endpoint;

    if (wifiName == savedWifiName) {
      endpoint = await _setLocalConnection();
    }

    endpoint ??= await _setRemoteConnection();

    return endpoint;
  }

  Future<String?> _setLocalConnection() async {
    try {
      final localEndpoint = _authRepository.getLocalEndpoint();
      if (localEndpoint != null) {
        await _apiService.resolveAndSetEndpoint(localEndpoint);
        return localEndpoint;
      }
    } catch (error, stackTrace) {
      _log.severe("Cannot set local endpoint", error, stackTrace);
    }

    return null;
  }

  Future<String?> _setRemoteConnection() async {
    List<AuxilaryEndpoint> endpointList;

    try {
      endpointList = _authRepository.getExternalEndpointList();
    } catch (error, stackTrace) {
      _log.severe("Cannot get external endpoint", error, stackTrace);
      return null;
    }

    for (final endpoint in endpointList) {
      try {
        return await _apiService.resolveAndSetEndpoint(endpoint.url);
      } on ApiException catch (error) {
        _log.severe("Cannot resolve endpoint", error);
        continue;
      } catch (_) {
        _log.severe("Auxiliary server is not valid");
        continue;
      }
    }

    return null;
  }

  Future<bool> unlockPinCode(String pinCode) {
    return _authApiRepository.unlockPinCode(pinCode);
  }

  Future<void> lockPinCode() {
    return _authApiRepository.lockPinCode();
  }

  Future<void> setupPinCode(String pinCode) {
    return _authApiRepository.setupPinCode(pinCode);
  }
}

abstract interface class AuthenticationPersistence {
  Future<void> markSessionNotReady();

  Future<void> delete<T>(StoreKey<T> key);
}

final class StoreAuthenticationPersistence implements AuthenticationPersistence {
  const StoreAuthenticationPersistence();

  @override
  Future<void> markSessionNotReady() => Store.put(StoreKey.authenticatedSessionReady, false);

  @override
  Future<void> delete<T>(StoreKey<T> key) => Store.delete(key);
}

final class AuthenticatedSessionTombstoneWriteFailure implements Exception {
  const AuthenticatedSessionTombstoneWriteFailure(this.cause);

  final Object cause;

  @override
  String toString() => 'Unable to durably block the authenticated session: $cause';
}
