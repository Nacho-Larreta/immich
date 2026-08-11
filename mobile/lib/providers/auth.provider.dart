import 'dart:async';

import 'package:flutter_udid/flutter_udid.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/interfaces/anonymous_server_discovery.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/logout_outcome.model.dart';
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
import 'package:immich_mobile/utils/hash.dart';

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
    NetworkAuthRequestContextAdapter(() => ref.read(sessionEpochControllerProvider).current.sessionEpoch),
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
    readConfiguredEndpoint: () => endpointStore.read()?.apiEndpoint,
    readConfiguredEndpointPolicy: () => endpointStore.read()?.schemePolicy,
    cachedSessionReader: StoreCachedSessionReader(Store, userService),
    hasConfiguredServer: () => Store.tryGet(StoreKey.serverEndpoint)?.isNotEmpty == true,
    publishRemoteAuthenticationPhase: (phase) => ref.read(remoteAuthenticationPhaseProvider.notifier).state = phase,
    invalidateSession: ref.read(serverReachabilityCoordinatorProvider).logout,
    cancelRemoteMedia: ref.read(remoteMediaProvider).cancelAll,
    suspendRemoteShares: ref.read(assetMediaRepositoryProvider).suspendRemoteShares,
    cancelShares: ref.read(assetMediaRepositoryProvider).cancelAll,
    activateShares: ref.read(assetMediaRepositoryProvider).activateRemoteShares,
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

final class AuthenticationBootstrapException implements Exception {
  const AuthenticationBootstrapException(this.message);

  final String message;

  @override
  String toString() => 'AuthenticationBootstrapException: $message';
}

final class AuthenticationBootstrapRollbackException implements Exception {
  const AuthenticationBootstrapRollbackException({required this.cause, required this.failures});

  final Object cause;
  final List<AuthenticationRollbackFailure> failures;

  @override
  String toString() =>
      'AuthenticationBootstrapRollbackException: authentication failed ($cause); '
      'rollback failures (${failures.join(', ')})';
}

enum AuthenticationRollbackSurface { sessionReadiness, persistedAuthentication, nativeContext, apiGraph, widget }

final class AuthenticationRollbackFailure {
  const AuthenticationRollbackFailure(this.surface, this.error, this.stackTrace);

  final AuthenticationRollbackSurface surface;
  final Object error;
  final StackTrace stackTrace;

  @override
  String toString() => '${surface.name}: $error';
}

final class AuthenticationMutationCancelledException implements Exception {
  const AuthenticationMutationCancelledException();

  @override
  String toString() => 'AuthenticationMutationCancelledException: a newer session mutation superseded login';
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
  final EndpointSchemePolicy? Function() _readConfiguredEndpointPolicy;
  final Map<String, String> Function() _readCustomHeaders;
  final bool Function() _hasConfiguredServer;
  final void Function(RemoteAuthenticationPhase) _publishRemoteAuthenticationPhase;
  final Future<void> Function() _invalidateSession;
  final Future<void> Function() _cancelRemoteMedia;
  final Future<void> Function() _suspendRemoteShares;
  final Future<void> Function() _cancelShares;
  final void Function() _activateShares;
  final void Function() _stopBackup;
  final void Function() _disconnectWebsocket;
  final Future<void> Function(String) _persistAccessToken;
  final Future<void> Function() _clearPersistedAuthentication;
  final Future<void> Function(bool) _persistSessionReadiness;
  final Future<String> Function() _readOrCreateDeviceId;
  final Future<void> Function(String) _persistDeviceIdentity;
  final Future<void> Function(String) _publishWidgetCredentials;
  Future<void>? _remoteAuthenticationTermination;
  _RemoteAuthenticationTerminationIntent? _requestedTerminationIntent;
  _RemoteAuthenticationTerminationIntent? _queuedTerminationIntent;
  bool _acceptsTerminationEscalation = false;
  int _authenticationGeneration = 0;

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
    EndpointSchemePolicy? Function()? readConfiguredEndpointPolicy,
    Map<String, String> Function()? readCustomHeaders,
    bool Function()? hasConfiguredServer,
    void Function(RemoteAuthenticationPhase)? publishRemoteAuthenticationPhase,
    required Future<void> Function() invalidateSession,
    required Future<void> Function() cancelRemoteMedia,
    Future<void> Function()? suspendRemoteShares,
    Future<void> Function()? cancelShares,
    void Function()? activateShares,
    required void Function() stopBackup,
    required void Function() disconnectWebsocket,
    Future<void> Function(String)? persistAccessToken,
    Future<void> Function()? clearPersistedAuthentication,
    Future<void> Function(bool)? persistSessionReadiness,
    Future<String> Function()? readOrCreateDeviceId,
    Future<void> Function(String)? persistDeviceIdentity,
    Future<void> Function(String)? publishWidgetCredentials,
  }) : _cachedSessionReader = cachedSessionReader,
       _anonymousServerDiscovery = anonymousServerDiscovery,
       _serverEndpointInstaller = serverEndpointInstaller,
       _readConfiguredEndpoint = readConfiguredEndpoint ?? _readStoredServerEndpoint,
       _readConfiguredEndpointPolicy = readConfiguredEndpointPolicy ?? _readStoredServerEndpointPolicy,
       _readCustomHeaders = readCustomHeaders ?? ApiService.getRequestHeaders,
       _hasConfiguredServer = hasConfiguredServer ?? _noConfiguredServer,
       _publishRemoteAuthenticationPhase = publishRemoteAuthenticationPhase ?? _noRemoteAuthenticationPhaseUpdate,
       _invalidateSession = invalidateSession,
       _cancelRemoteMedia = cancelRemoteMedia,
       _suspendRemoteShares = suspendRemoteShares ?? _noAsyncWork,
       _cancelShares = cancelShares ?? _noAsyncWork,
       _activateShares = activateShares ?? _noWork,
       _stopBackup = stopBackup,
       _disconnectWebsocket = disconnectWebsocket,
       _persistAccessToken = persistAccessToken ?? _storeAccessToken,
       _clearPersistedAuthentication = clearPersistedAuthentication ?? _authService.clearRemoteAuthentication,
       _persistSessionReadiness = persistSessionReadiness ?? _storeSessionReadiness,
       _readOrCreateDeviceId = readOrCreateDeviceId ?? _storedOrGeneratedDeviceId,
       _persistDeviceIdentity = persistDeviceIdentity ?? _storeDeviceIdentity,
       _publishWidgetCredentials =
           publishWidgetCredentials ??
           ((accessToken) {
             final serverEndpoint = Store.get(StoreKey.serverEndpoint);
             final customHeaders = Store.tryGet(StoreKey.customHeaders);
             return _widgetService.writeCredentialsAndRefresh(serverEndpoint, accessToken, customHeaders);
           }),
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
    _publishRemoteAuthenticationPhase(RemoteAuthenticationPhase.authenticated);
    _activateShares();
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
    final generation = _authenticationGeneration;
    return _sessionMutationMutex.protect(() async {
      _ensureAuthenticationMutationIsCurrent(generation);
      final response = await _authService.login(email, password);
      _ensureAuthenticationMutationIsCurrent(generation);
      await _establishAuthenticatedSession(accessToken: response.accessToken, generation: generation);
      return response;
    });
  }

  Future<void> logout() => _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent.logout);

  Future<LogoutOutcome> logoutWithOutcome() async {
    try {
      await logout();
      return const LogoutSuccess();
    } on Object catch (error) {
      return state.isAuthenticated ? LogoutNotCleared(error) : LogoutClearedWithWarning(error);
    }
  }

  Future<void> requireReauthentication() =>
      _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent.reauthenticate);

  Future<void> forgetServer() =>
      _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent.forgetServer);

  Future<void> _requestRemoteAuthenticationTermination(_RemoteAuthenticationTerminationIntent intent) {
    _authenticationGeneration++;
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
    final termination = _beginRemoteAuthenticationTermination().whenComplete(() {
      _remoteAuthenticationTermination = null;
      _requestedTerminationIntent = null;
      _acceptsTerminationEscalation = false;
    });
    _remoteAuthenticationTermination = termination;
    return termination;
  }

  Future<void> _beginRemoteAuthenticationTermination() async {
    await _persistSessionReadiness(false);
    final remoteShareSuspension = _suspendRemoteShares();
    await _coordinateRemoteAuthenticationTermination(remoteShareSuspension);
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

  Future<void> _coordinateRemoteAuthenticationTermination(Future<void> remoteShareSuspension) async {
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
    await invalidate(() => remoteShareSuspension);
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

  static EndpointSchemePolicy? _readStoredServerEndpointPolicy() {
    final endpoint = _readStoredServerEndpoint();
    if (endpoint == null) return null;
    return parseEndpointSchemePolicy(Store.tryGet(StoreKey.serverEndpointSchemePolicy)) ??
        (endpoint.scheme == 'https' ? EndpointSchemePolicy.httpsOnly : null);
  }

  static Future<void> _storeAccessToken(String accessToken) {
    return Store.put(StoreKey.accessToken, accessToken);
  }

  static Future<void> _storeSessionReadiness(bool ready) {
    return Store.put(StoreKey.authenticatedSessionReady, ready);
  }

  static Future<String> _storedOrGeneratedDeviceId() async {
    return Store.tryGet(StoreKey.deviceId) ?? await FlutterUdid.consistentUdid;
  }

  static Future<void> _storeDeviceIdentity(String deviceId) async {
    await Store.put(StoreKey.deviceId, deviceId);
    await Store.put(StoreKey.deviceIdHash, fastHash(deviceId));
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
    var sharesCancelled = false;
    var remoteSessionInvalidated = false;
    var remoteAuthenticationCleared = false;
    var serverForgotten = false;

    try {
      await attempt(() => _ref.read(backgroundUploadServiceProvider).cancel(), recordOperationError);
      await attempt(() => _ref.read(foregroundUploadServiceProvider).cancel(), recordOperationError);
      await attempt(() => _secureStorageService.delete(kSecuredPinCode), recordOperationError);

      while (true) {
        final requestedIntent = _requestedTerminationIntent ?? _RemoteAuthenticationTerminationIntent.reauthenticate;
        if (requestedIntent.priority >= _RemoteAuthenticationTerminationIntent.logout.priority && !sharesCancelled) {
          await attempt(_cancelShares, recordOperationError);
          sharesCancelled = true;
        }
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

  Future<bool> saveAuthInfo({required String accessToken}) {
    final generation = _authenticationGeneration;
    return _sessionMutationMutex.protect(() async {
      _ensureAuthenticationMutationIsCurrent(generation);
      await _establishAuthenticatedSession(accessToken: accessToken, generation: generation);
      return true;
    });
  }

  Future<void> _establishAuthenticatedSession({required String accessToken, required int generation}) async {
    try {
      final endpoint = _readConfiguredEndpoint();
      final schemePolicy = _readConfiguredEndpointPolicy();
      if (endpoint == null || schemePolicy == null) {
        throw const AuthenticationBootstrapException('The active server has no approved request context');
      }
      final canonicalOrigin = Uri.parse(endpoint.origin);
      validateEndpointSchemePolicy(canonicalOrigin, schemePolicy);

      _ensureAuthenticationMutationIsCurrent(generation);
      await _persistSessionReadiness(false);
      _ensureAuthenticationMutationIsCurrent(generation);
      await _persistAccessToken(accessToken);
      _ensureAuthenticationMutationIsCurrent(generation);
      await _requestContext.install(
        apiEndpoint: endpoint,
        canonicalOrigin: canonicalOrigin,
        accessToken: accessToken,
        schemePolicy: schemePolicy,
        customHeaders: _readCustomHeaders(),
      );
      _ensureAuthenticationMutationIsCurrent(generation);
      final deviceId = await _readOrCreateDeviceId();
      _ensureAuthenticationMutationIsCurrent(generation);
      final user = await _userService.refreshMyUser().timeout(_timeoutDuration);
      if (user == null) {
        throw const AuthenticationBootstrapException('The server returned no current user');
      }

      _ensureAuthenticationMutationIsCurrent(generation);
      await _persistDeviceIdentity(deviceId);
      _ensureAuthenticationMutationIsCurrent(generation);
      await _publishWidgetCredentials(accessToken);
      _ensureAuthenticationMutationIsCurrent(generation);
      await _persistSessionReadiness(true);
      _ensureAuthenticationMutationIsCurrent(generation);

      state = state.copyWith(
        deviceId: deviceId,
        userId: user.id,
        userEmail: user.email,
        isAuthenticated: true,
        name: user.name,
        isAdmin: user.isAdmin,
      );
      _publishRemoteAuthenticationPhase(RemoteAuthenticationPhase.authenticated);
      _activateShares();
    } catch (error, stackTrace) {
      await _rollbackAuthenticationBootstrap(error, stackTrace);
    }
  }

  void _ensureAuthenticationMutationIsCurrent(int generation) {
    if (generation != _authenticationGeneration || _remoteAuthenticationTermination != null) {
      throw const AuthenticationMutationCancelledException();
    }
  }

  Future<Never> _rollbackAuthenticationBootstrap(Object cause, StackTrace causeStackTrace) async {
    _requestContext.block();
    final remoteShareSuspension = _suspendRemoteShares();
    final failures = <AuthenticationRollbackFailure>[];

    Future<void> attempt(AuthenticationRollbackSurface surface, Future<void> Function() operation) async {
      try {
        await operation();
      } catch (error, stackTrace) {
        failures.add(AuthenticationRollbackFailure(surface, error, stackTrace));
      }
    }

    await attempt(AuthenticationRollbackSurface.sessionReadiness, () => _persistSessionReadiness(false));
    await remoteShareSuspension;
    await attempt(AuthenticationRollbackSurface.persistedAuthentication, _clearPersistedAuthentication);
    await attempt(AuthenticationRollbackSurface.nativeContext, _requestContext.purge);
    await attempt(AuthenticationRollbackSurface.apiGraph, _apiGraph.purge);
    await attempt(AuthenticationRollbackSurface.widget, _widgetService.clearCredentialsAndRefresh);
    _requestContext.block();

    _publishUnauthenticatedState();
    _publishRemoteAuthenticationPhase(RemoteAuthenticationPhase.reauthenticationRequired);

    if (failures.isNotEmpty) {
      Error.throwWithStackTrace(
        AuthenticationBootstrapRollbackException(cause: cause, failures: List.unmodifiable(failures)),
        failures.first.stackTrace,
      );
    }
    Error.throwWithStackTrace(cause, causeStackTrace);
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
