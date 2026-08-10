import 'dart:async';

import 'package:flutter_udid/flutter_udid.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/interfaces/anonymous_server_discovery.interface.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/domain/interfaces/resolved_server_endpoint_installer.interface.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/auth/network_auth_request_context_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/resolved_server_endpoint_installer_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/service_endpoint_activation_collaborators.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/anonymous_server_discovery_adapter.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/models/auth/auth_state.model.dart';
import 'package:immich_mobile/models/auth/login_response.model.dart';
import 'package:immich_mobile/providers/api.provider.dart';
import 'package:immich_mobile/providers/cached_session.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/remote_media.provider.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/session_mutation.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
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
  final apiService = ref.watch(apiServiceProvider);
  final sessionMutationMutex = ref.watch(sessionMutationMutexProvider);
  final apiGraph = ApiServiceEndpointGraphAdapter(apiService);
  const nativeRequestContext = NetworkNativeRequestContextAdapter();
  const endpointStore = StoreConfirmedEndpointAdapter();
  return AuthNotifier(
    ref.watch(authServiceProvider),
    apiService,
    userService,
    ref.watch(secureStorageServiceProvider),
    ref.watch(widgetServiceProvider),
    const NetworkAuthRequestContextAdapter(),
    apiGraph,
    sessionMutationMutex,
    ref,
    anonymousServerDiscovery: AnonymousServerDiscoveryAdapter(transport: ref.watch(probeHttpTransportProvider)),
    serverEndpointInstaller: ResolvedServerEndpointInstallerAdapter(
      mutex: sessionMutationMutex,
      apiGraph: apiGraph,
      nativeContext: nativeRequestContext,
      endpointStore: endpointStore,
      installDeviceInfoHeaders: apiService.setDeviceInfoHeader,
    ),
    readConfiguredEndpoint: endpointStore.read,
    cachedSessionReader: StoreCachedSessionReader(Store, userService),
    hasConfiguredServer: () => Store.tryGet(StoreKey.serverEndpoint)?.isNotEmpty == true,
    publishRemoteAuthenticationPhase: (phase) => ref.read(remoteAuthenticationPhaseProvider.notifier).state = phase,
    invalidateSession: ref.read(serverReachabilityCoordinatorProvider).logout,
    cancelRemoteMedia: ref.read(remoteMediaProvider).cancelAll,
    cancelShares: ref.read(assetMediaRepositoryProvider).cancelAll,
    activateShares: ref.read(assetMediaRepositoryProvider).activateSession,
    stopBackup: ref.read(driftBackupProvider.notifier).stopForegroundBackup,
    disconnectWebsocket: ref.read(websocketProvider.notifier).disconnect,
  );
});

enum _RemoteAuthenticationTerminationIntent { reauthenticate, logout, forgetServer }

extension on _RemoteAuthenticationTerminationIntent {
  int get priority => switch (this) {
    _RemoteAuthenticationTerminationIntent.reauthenticate => 0,
    _RemoteAuthenticationTerminationIntent.logout => 1,
    _RemoteAuthenticationTerminationIntent.forgetServer => 2,
  };
}

final class RemoteAuthenticationTerminationSequenceException implements Exception {
  const RemoteAuthenticationTerminationSequenceException({required this.precedingError, required this.queuedError});

  final Object precedingError;
  final Object queuedError;

  @override
  String toString() {
    return 'RemoteAuthenticationTerminationSequenceException: preceding termination failed ($precedingError); '
        'queued termination failed ($queuedError)';
  }
}

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
  final AnonymousServerDiscoveryPort _anonymousServerDiscovery;
  final ResolvedServerEndpointInstallerPort _serverEndpointInstaller;
  final Uri? Function() _readConfiguredEndpoint;
  final bool Function() _hasConfiguredServer;
  final void Function(RemoteAuthenticationPhase) _publishRemoteAuthenticationPhase;
  final Future<void> Function() _invalidateSession;
  final Future<void> Function() _cancelRemoteMedia;
  final Future<void> Function() _cancelShares;
  final void Function() _activateShares;
  final void Function() _stopBackup;
  final void Function() _disconnectWebsocket;
  final _log = Logger("AuthenticationNotifier");
  Future<void>? _remoteAuthenticationTermination;
  _RemoteAuthenticationTerminationIntent? _requestedTerminationIntent;
  _RemoteAuthenticationTerminationIntent? _queuedTerminationIntent;
  bool _acceptsTerminationEscalation = false;

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
    required AnonymousServerDiscoveryPort anonymousServerDiscovery,
    required ResolvedServerEndpointInstallerPort serverEndpointInstaller,
    Uri? Function()? readConfiguredEndpoint,
    bool Function()? hasConfiguredServer,
    void Function(RemoteAuthenticationPhase)? publishRemoteAuthenticationPhase,
    required Future<void> Function() invalidateSession,
    required Future<void> Function() cancelRemoteMedia,
    Future<void> Function()? cancelShares,
    void Function()? activateShares,
    required void Function() stopBackup,
    required void Function() disconnectWebsocket,
  }) : _cachedSessionReader = cachedSessionReader,
       _anonymousServerDiscovery = anonymousServerDiscovery,
       _serverEndpointInstaller = serverEndpointInstaller,
       _readConfiguredEndpoint = readConfiguredEndpoint ?? _readStoredServerEndpoint,
       _hasConfiguredServer = hasConfiguredServer ?? _noConfiguredServer,
       _publishRemoteAuthenticationPhase = publishRemoteAuthenticationPhase ?? _noRemoteAuthenticationPhaseUpdate,
       _invalidateSession = invalidateSession,
       _cancelRemoteMedia = cancelRemoteMedia,
       _cancelShares = cancelShares ?? _noAsyncWork,
       _activateShares = activateShares ?? _noWork,
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
    _activateShares();
    _publishRemoteAuthenticationPhase(RemoteAuthenticationPhase.authenticated);
    return true;
  }

  Future<String> validateServerUrl(String url) async {
    final endpoint = await _anonymousServerDiscovery.discover(url);
    final currentEndpoint = _readConfiguredEndpoint();
    if (currentEndpoint != null && currentEndpoint.origin != endpoint.canonicalOrigin.origin) {
      await forgetServer();
    }
    await _serverEndpointInstaller.installResolvedServerEndpoint(endpoint);
    _publishUnauthenticatedState();
    _publishRemoteAuthenticationPhase(RemoteAuthenticationPhase.reauthenticationRequired);
    return endpoint.apiEndpoint.toString();
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
    _activateShares();
    return response;
  }

  Future<void> logout() => _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent.logout);

  Future<void> requireReauthentication() =>
      _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent.reauthenticate);

  Future<void> forgetServer() =>
      _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent.forgetServer);

  Future<void> _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent intent) {
    _requestContext.block();
    final activeTermination = _remoteAuthenticationTermination;
    if (activeTermination != null) {
      if (_acceptsTerminationEscalation) {
        _requestedTerminationIntent = _strongerIntent(_requestedTerminationIntent, intent);
        return activeTermination;
      }
      _queuedTerminationIntent = _strongerIntent(_queuedTerminationIntent, intent);
      return _continueAfterRemoteAuthenticationTermination(activeTermination, intent);
    }

    _queuedTerminationIntent = null;
    _requestedTerminationIntent = intent;
    _acceptsTerminationEscalation = true;
    final termination = _coordinateRemoteAuthenticationTermination().whenComplete(() {
      _remoteAuthenticationTermination = null;
      _requestedTerminationIntent = null;
      _acceptsTerminationEscalation = false;
    });
    _remoteAuthenticationTermination = termination;
    return termination;
  }

  Future<void> _continueAfterRemoteAuthenticationTermination(
    Future<void> activeTermination,
    _RemoteAuthenticationTerminationIntent intent,
  ) async {
    Object? precedingError;
    try {
      await activeTermination;
    } catch (error) {
      precedingError = error;
    }

    try {
      await _requestRemoteAuthenticationTermination(intent);
    } catch (queuedError, queuedStackTrace) {
      if (precedingError != null) {
        Error.throwWithStackTrace(
          RemoteAuthenticationTerminationSequenceException(precedingError: precedingError, queuedError: queuedError),
          queuedStackTrace,
        );
      }
      Error.throwWithStackTrace(queuedError, queuedStackTrace);
    }
  }

  _RemoteAuthenticationTerminationIntent _strongerIntent(
    _RemoteAuthenticationTerminationIntent? current,
    _RemoteAuthenticationTerminationIntent requested,
  ) {
    if (current == null || requested.priority > current.priority) {
      return requested;
    }
    return current;
  }

  Future<void> _coordinateRemoteAuthenticationTermination() async {
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
    await invalidate(_cancelRemoteMedia);
    await invalidate(_cancelShares);
    await invalidate(_stopBackup);
    await invalidate(_disconnectWebsocket);
    await _sessionMutationMutex.protect(_applyRequestedRemoteAuthenticationTermination);
    if (invalidationError != null) {
      Error.throwWithStackTrace(invalidationError!, invalidationStackTrace!);
    }
  }

  static Future<void> _noAsyncWork() async {}

  static void _noWork() {}

  static void _noRemoteAuthenticationPhaseUpdate(RemoteAuthenticationPhase _) {}

  static bool _noConfiguredServer() => false;

  static Uri? _readStoredServerEndpoint() {
    final endpoint = Store.tryGet(StoreKey.serverEndpoint);
    return endpoint == null || endpoint.isEmpty ? null : Uri.parse(endpoint);
  }

  Future<void> _applyRequestedRemoteAuthenticationTermination() async {
    Object? operationError;
    StackTrace? operationStackTrace;
    Object? cleanupError;
    StackTrace? cleanupStackTrace;
    Future<bool> attempt(FutureOr<void> Function() operation, void Function(Object, StackTrace) onError) async {
      try {
        await operation();
        return true;
      } catch (error, stackTrace) {
        onError(error, stackTrace);
        return false;
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

    var appliedIntent = _RemoteAuthenticationTerminationIntent.reauthenticate;
    var remoteSessionInvalidated = false;
    var remoteAuthenticationCleared = false;
    var serverForgotten = false;

    try {
      await attempt(() => _ref.read(backgroundUploadServiceProvider).cancel(), recordOperationError);
      await attempt(() => _ref.read(foregroundUploadServiceProvider).cancel(), recordOperationError);
      await attempt(() => _secureStorageService.delete(kSecuredPinCode), recordOperationError);

      while (true) {
        final requestedIntent = _requestedTerminationIntent ?? _RemoteAuthenticationTerminationIntent.reauthenticate;
        if (requestedIntent.priority >= _RemoteAuthenticationTerminationIntent.logout.priority &&
            !remoteSessionInvalidated) {
          await attempt(_authService.invalidateRemoteSession, recordOperationError);
          remoteSessionInvalidated = true;
        }

        if (requestedIntent == _RemoteAuthenticationTerminationIntent.forgetServer && !serverForgotten) {
          if (!await attempt(_authService.forgetServer, recordCleanupError)) {
            break;
          }
          serverForgotten = true;
          remoteAuthenticationCleared = true;
        } else if (!remoteAuthenticationCleared) {
          if (!await attempt(_authService.clearRemoteAuthentication, recordCleanupError)) {
            break;
          }
          remoteAuthenticationCleared = true;
        }

        appliedIntent = requestedIntent;
        final latestIntent = _requestedTerminationIntent ?? requestedIntent;
        if (latestIntent.priority <= appliedIntent.priority) {
          break;
        }
      }
    } finally {
      _acceptsTerminationEscalation = false;
      await Future.wait([
        attempt(_widgetService.clearCredentialsAndRefresh, recordCleanupError),
        attempt(_apiGraph.purge, recordCleanupError),
        attempt(_requestContext.purge, recordCleanupError),
      ]);
      if (cleanupError != null) {
        _requestContext.block();
      } else {
        try {
          if (_queuedTerminationIntent == null) {
            _requestContext.publishCleared();
          }
        } catch (error, stackTrace) {
          recordCleanupError(error, stackTrace);
          _requestContext.block();
        }
      }
    }

    if (cleanupError != null) {
      Error.throwWithStackTrace(cleanupError!, cleanupStackTrace!);
    }

    _publishUnauthenticatedState();
    _publishRemoteAuthenticationPhase(
      appliedIntent == _RemoteAuthenticationTerminationIntent.forgetServer
          ? RemoteAuthenticationPhase.unconfigured
          : _phaseAfterAuthenticationClear(),
    );
    if (operationError != null) {
      Error.throwWithStackTrace(operationError!, operationStackTrace!);
    }
  }

  void _publishUnauthenticatedState() {
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

  RemoteAuthenticationPhase _phaseAfterAuthenticationClear() {
    return !_hasConfiguredServer()
        ? RemoteAuthenticationPhase.unconfigured
        : RemoteAuthenticationPhase.reauthenticationRequired;
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
        _log.warning("Unauthorized access, remote authentication is required again.");
        await requireReauthentication();
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
    _publishRemoteAuthenticationPhase(RemoteAuthenticationPhase.authenticated);

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
