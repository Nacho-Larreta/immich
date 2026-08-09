import 'dart:async';

import 'package:flutter_udid/flutter_udid.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/auth/network_auth_request_context_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/service_endpoint_activation_collaborators.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/models/auth/login_response.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/cached_session.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/local_media.provider.dart';
import 'package:immich_mobile/providers/remote_media.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/session_mutation.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/hash.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';

final authProvider = StateNotifierProvider<AuthNotifier, AuthState>((ref) {
  final userService = ref.watch(userServiceProvider);
  return AuthNotifier(
    ref.watch(authServiceProvider),
    ref.watch(apiServiceProvider),
    userService,
    ref.watch(secureStorageServiceProvider),
    ref.watch(widgetServiceProvider),
    const NetworkAuthRequestContextAdapter(),
    ApiServiceEndpointGraphAdapter(ref.watch(apiServiceProvider)),
    ref.watch(sessionMutationMutexProvider),
    ref,
    cachedSessionReader: StoreCachedSessionReader(Store, userService),
    invalidateSession: ref.read(serverReachabilityCoordinatorProvider).logout,
    cancelLocalMedia: ref.read(localMediaProvider).cancelAll,
    cancelRemoteMedia: ref.read(remoteMediaProvider).cancelAll,
    stopBackup: ref.read(driftBackupProvider.notifier).stopForegroundBackup,
    disconnectWebsocket: ref.read(websocketProvider.notifier).disconnect,
  );
});

class AuthNotifier extends StateNotifier<AuthState> {
  final AuthService _authService;
  final ApiService _apiService;
  final UserService _userService;

  final SecureStorageService _secureStorageService;
  final WidgetService _widgetService;
  final AuthRequestContextPort _requestContext;
  final AuthApiGraphPort _apiGraph;
  final SessionMutationMutex _sessionMutationMutex;
  final Ref _ref;
  final CachedSessionReader _cachedSessionReader;
  final Future<void> Function() _invalidateSession;
  final Future<void> Function() _cancelLocalMedia;
  final Future<void> Function() _cancelRemoteMedia;
  final void Function() _stopBackup;
  final void Function() _disconnectWebsocket;
  final _log = Logger("AuthenticationNotifier");
  Future<void>? _logoutFuture;

  static const Duration _timeoutDuration = Duration(seconds: 7);

  AuthNotifier(
    this._authService,
    this._apiService,
    this._userService,

    this._secureStorageService,
    this._widgetService,
    this._requestContext,
    this._apiGraph,
    this._sessionMutationMutex,
    this._ref, {
    required CachedSessionReader cachedSessionReader,
    required Future<void> Function() invalidateSession,
    required Future<void> Function() cancelLocalMedia,
    required Future<void> Function() cancelRemoteMedia,
    required void Function() stopBackup,
    required void Function() disconnectWebsocket,
  }) : _cachedSessionReader = cachedSessionReader,
       _invalidateSession = invalidateSession,
       _cancelLocalMedia = cancelLocalMedia,
       _cancelRemoteMedia = cancelRemoteMedia,
       _stopBackup = stopBackup,
       _disconnectWebsocket = disconnectWebsocket,
       super(
         const AuthState(
           deviceId: "",
           userId: "",
           userEmail: "",
           name: '',
           profileImagePath: '',
           isAdmin: false,
           isAuthenticated: false,
         ),
       );

  bool hydrateCachedSession() {
    final session = _cachedSessionReader.read();
    if (session == null) {
      return false;
    }

    final user = session.user;
    state = state.copyWith(
      deviceId: session.deviceId ?? '',
      userId: user.id,
      userEmail: user.email,
      isAuthenticated: true,
      name: user.name,
      isAdmin: user.isAdmin,
    );
    return true;
  }

  Future<String> validateServerUrl(String url) {
    return _authService.validateServerUrl(url);
  }

  /// Validating the url is the alternative connecting server url without
  /// saving the information to the local database
  Future<bool> validateAuxilaryServerUrl(String url) async {
    try {
      final validEndpoint = await _apiService.resolveEndpoint(url);
      return await _authService.validateAuxilaryServerUrl(validEndpoint);
    } catch (_) {
      return false;
    }
  }

  Future<LoginResponse> login(String email, String password) async {
    final response = await _authService.login(email, password);
    await saveAuthInfo(accessToken: response.accessToken);
    return response;
  }

  Future<void> logout() => _logoutFuture ??= _coordinateLogout().whenComplete(() => _logoutFuture = null);

  Future<void> _coordinateLogout() async {
    Object? invalidationError;
    StackTrace? invalidationStackTrace;

    Future<void> invalidate(FutureOr<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        invalidationError ??= error;
        invalidationStackTrace ??= stackTrace;
      }
    }

    await invalidate(_invalidateSession);
    await invalidate(_cancelLocalMedia);
    await invalidate(_cancelRemoteMedia);
    await invalidate(_stopBackup);
    await invalidate(_disconnectWebsocket);
    await _sessionMutationMutex.protect(_logout);
    if (invalidationError != null) {
      Error.throwWithStackTrace(invalidationError!, invalidationStackTrace!);
    }
  }

  Future<void> _logout() async {
    Object? operationError;
    StackTrace? operationStackTrace;
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    Future<void> attempt(FutureOr<void> Function() operation, void Function(Object, StackTrace) onError) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        onError(error, stackTrace);
      }
    }

    void recordOperationError(Object error, StackTrace stackTrace) {
      operationError ??= error;
      operationStackTrace ??= stackTrace;
    }

    void recordCleanupError(Object error, StackTrace stackTrace) {
      cleanupError ??= error;
      cleanupStackTrace ??= stackTrace;
    }

    try {
      await attempt(() => _ref.read(backgroundUploadServiceProvider).cancel(), recordOperationError);
      await attempt(() => _ref.read(foregroundUploadServiceProvider).cancel(), recordOperationError);
      await attempt(() => _secureStorageService.delete(kSecuredPinCode), recordOperationError);
      await attempt(_authService.invalidateRemoteSession, recordOperationError);
    } finally {
      _requestContext.block();
      await Future.wait([
        attempt(_authService.clearLocalSession, recordCleanupError),
        attempt(_widgetService.clearCredentialsAndRefresh, recordCleanupError),
        attempt(_apiGraph.purge, recordCleanupError),
        attempt(_requestContext.purge, recordCleanupError),
      ]);
      if (cleanupError != null) {
        _requestContext.block();
      } else {
        try {
          _requestContext.publishCleared();
        } catch (error, stackTrace) {
          recordCleanupError(error, stackTrace);
          _requestContext.block();
        }
      }
    }

    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStackTrace!);
    }

    await _cleanUp();
    if (operationError != null) {
      Error.throwWithStackTrace(operationError!, operationStackTrace!);
    }
  }

  Future<void> _cleanUp() async {
    state = const AuthState(
      deviceId: "",
      userId: "",
      userEmail: "",
      name: '',
      profileImagePath: '',
      isAdmin: false,
      isAuthenticated: false,
    );
  }

  void updateUserProfileImagePath(String path) {
    state = state.copyWith(profileImagePath: path);
  }

  Future<bool> changePassword(String newPassword) async {
    try {
      await _authService.changePassword(newPassword);
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> saveAuthInfo({required String accessToken}) async {
    await Store.put(StoreKey.accessToken, accessToken);
    await _apiService.updateHeaders();

    final serverEndpoint = Store.get(StoreKey.serverEndpoint);
    final customHeaders = Store.tryGet(StoreKey.customHeaders);
    await _widgetService.writeCredentialsAndRefresh(serverEndpoint, accessToken, customHeaders);

    // Get the deviceid from the store if it exists, otherwise generate a new one
    String deviceId = Store.tryGet(StoreKey.deviceId) ?? await FlutterUdid.consistentUdid;

    UserDto? user = _userService.tryGetMyUser();

    try {
      final serverUser = await _userService.refreshMyUser().timeout(_timeoutDuration);
      if (serverUser == null) {
        _log.severe("Unable to get user information from the server.");
      } else {
        // If the user information is successfully retrieved, update the store
        // Due to the flow of the code, this will always happen on first login
        user = serverUser;
        await Store.put(StoreKey.deviceId, deviceId);
        await Store.put(StoreKey.deviceIdHash, fastHash(deviceId));
      }
    } on ApiException catch (error, stackTrace) {
      if (error.code == 401) {
        _log.severe("Unauthorized access, token likely expired. Logging out.");
        return false;
      }
      _log.severe("Error getting user information from the server [API EXCEPTION]", stackTrace);
    } catch (error, stackTrace) {
      _log.severe("Error getting user information from the server [CATCH ALL]", error, stackTrace);
      dPrint(() => "Error getting user information from the server [CATCH ALL] $error $stackTrace");
    }

    // If the user is null, the login was not successful
    // and we don't have a local copy of the user from a prior successful login
    if (user == null) {
      return false;
    }

    state = state.copyWith(
      deviceId: deviceId,
      userId: user.id,
      userEmail: user.email,
      isAuthenticated: true,
      name: user.name,
      isAdmin: user.isAdmin,
    );

    return true;
  }

  Future<void> saveWifiName(String wifiName) async {
    await Store.put(StoreKey.preferredWifiName, wifiName);
  }

  Future<void> saveLocalEndpoint(String url) async {
    await Store.put(StoreKey.localEndpoint, url);
  }

  String? getSavedWifiName() {
    return Store.tryGet(StoreKey.preferredWifiName);
  }

  String? getSavedLocalEndpoint() {
    return Store.tryGet(StoreKey.localEndpoint);
  }

  /// Returns the current server endpoint (with /api) URL from the store
  String? getServerEndpoint() {
    return Store.tryGet(StoreKey.serverEndpoint);
  }

  Future<String?> setOpenApiServiceEndpoint() {
    return _authService.setOpenApiServiceEndpoint();
  }

  Future<bool> unlockPinCode(String pinCode) {
    return _authService.unlockPinCode(pinCode);
  }

  Future<void> lockPinCode() {
    return _authService.lockPinCode();
  }

  Future<void> setupPinCode(String pinCode) {
    return _authService.setupPinCode(pinCode);
  }
}
