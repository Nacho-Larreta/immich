import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/anonymous_server_discovery.interface.dart';
import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/domain/interfaces/resolved_server_endpoint_installer.interface.dart';
import 'package:immich_mobile/domain/interfaces/request_context_lease.interface.dart';
import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/logout_outcome.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/models/auth/login_response.model.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/cached_session.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

import '../fixtures/user.stub.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockAuthService extends Mock implements AuthService {}

class _MockAnonymousServerDiscovery extends Mock implements AnonymousServerDiscoveryPort {}

class _MockBackgroundUploadService extends Mock implements BackgroundUploadService {}

class _MockCachedSessionReader extends Mock implements CachedSessionReader {}

class _MockRef extends Mock implements Ref {}

class _MockForegroundUploadService extends Mock implements ForegroundUploadService {}

class _MockSecureStorageService extends Mock implements SecureStorageService {}

class _MockUserService extends Mock implements UserService {}

class _MockWidgetService extends Mock implements WidgetService {}

class _MockResolvedServerEndpointInstaller extends Mock implements ResolvedServerEndpointInstallerPort {}

class _MockEndpointApiGraph extends Mock implements EndpointApiGraphPort {}

class _MockNativeRequestContext extends Mock implements NativeRequestContextPort {}

class _MockConfirmedEndpointStore extends Mock implements ConfirmedEndpointStorePort {}

class _MockWidgetCredentials extends Mock implements WidgetCredentialsPort {}

final class _PreparedApiGraph extends Fake implements PreparedApiGraph {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uri.parse('https://fallback.test/api'));
    registerFallbackValue(
      DiscoveredServerEndpoint(
        canonicalOrigin: Uri.parse('https://fallback.test'),
        apiEndpoint: Uri.parse('https://fallback.test/api'),
      ),
    );
    registerFallbackValue(
      NativeRequestContext(canonicalOrigin: null, accessToken: null, schemePolicy: null, customHeaders: const {}),
    );
    registerFallbackValue(
      ConfirmedServerEndpoint(
        apiEndpoint: Uri.parse('https://fallback.test/api'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
    );
    registerFallbackValue(const WidgetCredentials(apiEndpoint: null, accessToken: null, customHeaders: null));
  });

  group('AuthNotifier.validateServerUrl', () {
    test('forgets server A before installing server B without touching local media', () async {
      final events = <String>[];
      final discovery = _MockAnonymousServerDiscovery();
      final installer = _MockResolvedServerEndpointInstaller();
      final serverB = DiscoveredServerEndpoint(
        canonicalOrigin: Uri.parse('https://server-b.example.test'),
        apiEndpoint: Uri.parse('https://server-b.example.test/api'),
      );
      when(() => discovery.discover('https://server-b.example.test')).thenAnswer((_) async => serverB);
      when(() => installer.installResolvedServerEndpoint(serverB)).thenAnswer((_) async => events.add('install B'));
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        anonymousServerDiscovery: discovery,
        serverEndpointInstaller: installer,
        readConfiguredEndpoint: () => Uri.parse('https://server-a.example.test/api'),
      );
      when(auth.authService.forgetServer).thenAnswer((_) async => events.add('forget A'));

      final endpoint = await auth.notifier.validateServerUrl('https://server-b.example.test');

      expect(endpoint, serverB.apiEndpoint.toString());
      expect(events, containsAllInOrder(['forget A', 'install B']));
      verify(auth.authService.forgetServer).called(1);
      verify(() => installer.installResolvedServerEndpoint(serverB)).called(1);
      expect(auth.notifier.state.isAuthenticated, isFalse);
    });

    test('reinstalls the endpoint without purging remote cache when canonical origin is unchanged', () async {
      final discovery = _MockAnonymousServerDiscovery();
      final installer = _MockResolvedServerEndpointInstaller();
      final endpoint = DiscoveredServerEndpoint(
        canonicalOrigin: Uri.parse('https://photos.example.test'),
        apiEndpoint: Uri.parse('https://photos.example.test/immich/api'),
      );
      when(() => discovery.discover(any())).thenAnswer((_) async => endpoint);
      when(() => installer.installResolvedServerEndpoint(endpoint)).thenAnswer((_) async {});
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        anonymousServerDiscovery: discovery,
        serverEndpointInstaller: installer,
        readConfiguredEndpoint: () => Uri.parse('https://photos.example.test/api'),
      );

      await auth.notifier.validateServerUrl('https://photos.example.test');

      verifyNever(auth.authService.forgetServer);
      verify(() => installer.installResolvedServerEndpoint(endpoint)).called(1);
    });

    test('installs a first server without running remote purge', () async {
      final phases = <RemoteAuthenticationPhase>[];
      final discovery = _MockAnonymousServerDiscovery();
      final installer = _MockResolvedServerEndpointInstaller();
      final endpoint = DiscoveredServerEndpoint(
        canonicalOrigin: Uri.parse('https://first.example.test'),
        apiEndpoint: Uri.parse('https://first.example.test/api'),
      );
      when(() => discovery.discover(any())).thenAnswer((_) async => endpoint);
      when(() => installer.installResolvedServerEndpoint(endpoint)).thenAnswer((_) async {});
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        anonymousServerDiscovery: discovery,
        serverEndpointInstaller: installer,
        readConfiguredEndpoint: () => null,
        publishRemoteAuthenticationPhase: phases.add,
      );

      await auth.notifier.validateServerUrl('https://first.example.test');

      verifyNever(auth.authService.forgetServer);
      verify(() => installer.installResolvedServerEndpoint(endpoint)).called(1);
      expect(phases.last, RemoteAuthenticationPhase.reauthenticationRequired);
    });
  });

  group('AuthNotifier.hydrateCachedSession', () {
    test('publishes cached auth without remote or native side effects', () {
      final authService = _MockAuthService();
      final apiService = _MockApiService();
      final userService = _MockUserService();
      final secureStorage = _MockSecureStorageService();
      final widgetService = _MockWidgetService();
      final reader = _MockCachedSessionReader();
      var shareActivations = 0;
      when(reader.read).thenReturn(
        CachedSession(
          accessToken: 'cached-token',
          apiEndpoint: Uri.parse('https://photos.example.test/immich/api'),
          user: UserStub.admin,
          deviceId: 'cached-device',
        ),
      );
      final notifier = AuthNotifier(
        authService,
        apiService,
        userService,
        secureStorage,
        widgetService,
        _RecordingAuthRequestContext(<String>[]),
        _RecordingAuthApiGraph(<String>[]),
        SessionMutationMutex(),
        _MockRef(),
        anonymousServerDiscovery: _MockAnonymousServerDiscovery(),
        serverEndpointInstaller: _MockResolvedServerEndpointInstaller(),
        cachedSessionReader: reader,
        invalidateSession: () async {},
        cancelRemoteMedia: () async {},
        activateShares: () => shareActivations++,
        stopBackup: () {},
        disconnectWebsocket: () {},
      );

      final hydrated = notifier.hydrateCachedSession();

      expect(hydrated, isTrue);
      expect(notifier.state.isAuthenticated, isTrue);
      expect(notifier.state.userId, UserStub.admin.id);
      expect(notifier.state.userEmail, UserStub.admin.email);
      expect(notifier.state.name, UserStub.admin.name);
      expect(notifier.state.isAdmin, isTrue);
      expect(notifier.state.deviceId, 'cached-device');
      expect(shareActivations, 1);
      verify(reader.read).called(1);
      verifyNever(apiService.updateHeaders);
      verifyNever(userService.refreshMyUser);
      verifyNever(() => widgetService.writeCredentialsAndRefresh(any(), any(), any()));
      verifyNoMoreInteractions(authService);
      verifyNoMoreInteractions(secureStorage);
    });

    test('keeps authentication false when required cached data is incomplete', () {
      final reader = _MockCachedSessionReader();
      when(reader.read).thenReturn(null);
      final notifier = AuthNotifier(
        _MockAuthService(),
        _MockApiService(),
        _MockUserService(),
        _MockSecureStorageService(),
        _MockWidgetService(),
        _RecordingAuthRequestContext(<String>[]),
        _RecordingAuthApiGraph(<String>[]),
        SessionMutationMutex(),
        _MockRef(),
        anonymousServerDiscovery: _MockAnonymousServerDiscovery(),
        serverEndpointInstaller: _MockResolvedServerEndpointInstaller(),
        cachedSessionReader: reader,
        invalidateSession: () async {},
        cancelRemoteMedia: () async {},
        stopBackup: () {},
        disconnectWebsocket: () {},
        persistSessionReadiness: (_) async {},
      );

      expect(notifier.hydrateCachedSession(), isFalse);
      expect(notifier.state.isAuthenticated, isFalse);
    });
  });

  group('AuthNotifier transactional login', () {
    test('never authenticates from a cached user when fresh bootstrap returns 401', () async {
      final unauthorized = ApiException(401, 'Unauthorized');
      final auth = _LoginFixture();
      when(auth.userService.tryGetMyUser).thenReturn(UserStub.admin);
      when(auth.userService.refreshMyUser).thenThrow(unauthorized);

      await expectLater(auth.notifier.login('user@test', 'password'), throwsA(same(unauthorized)));

      expect(auth.notifier.state.isAuthenticated, isFalse);
      expect(auth.shareActivations, 0);
      expect(auth.shareSuspensions, 1);
      expect(auth.widgetCredentialWrites, 0);
      expect(auth.phases.last, RemoteAuthenticationPhase.reauthenticationRequired);
      verifyNever(auth.userService.tryGetMyUser);
      verify(auth.authService.clearRemoteAuthentication).called(1);
    });

    test('rolls back a non-401 OAuth bootstrap failure without publishing a partial session', () async {
      final failure = StateError('preferences unavailable');
      final auth = _LoginFixture();
      when(auth.userService.refreshMyUser).thenThrow(failure);

      await expectLater(auth.notifier.saveAuthInfo(accessToken: 'oauth-token'), throwsA(same(failure)));

      expect(auth.notifier.state.isAuthenticated, isFalse);
      expect(auth.shareActivations, 0);
      expect(auth.shareSuspensions, 1);
      expect(auth.widgetCredentialWrites, 0);
      expect(auth.persistedTokens, ['oauth-token']);
      expect(auth.persistedAccessToken, isNull);
      verify(auth.authService.clearRemoteAuthentication).called(1);
      verify(auth.widgetService.clearCredentialsAndRefresh).called(1);
    });

    test('attempts every rollback surface and remains fenced when cleanup is incomplete', () async {
      final auth = _LoginFixture();
      when(auth.userService.refreshMyUser).thenThrow(StateError('bootstrap failed'));
      when(auth.authService.clearRemoteAuthentication).thenThrow(StateError('store cleanup failed'));
      when(auth.widgetService.clearCredentialsAndRefresh).thenThrow(StateError('widget cleanup failed'));
      auth.requestContext.purgeError = StateError('native cleanup failed');
      auth.apiGraph.purgeError = StateError('graph cleanup failed');

      await expectLater(
        auth.notifier.login('user@test', 'password'),
        throwsA(
          isA<AuthenticationBootstrapRollbackException>()
              .having((error) => error.failures.map((failure) => failure.surface), 'rollback surfaces', [
                AuthenticationRollbackSurface.persistedAuthentication,
                AuthenticationRollbackSurface.nativeContext,
                AuthenticationRollbackSurface.apiGraph,
                AuthenticationRollbackSurface.widget,
              ]),
        ),
      );

      expect(auth.requestContext.blocked, isTrue);
      expect(auth.requestContext.events, isNot(contains('network.publishCleared')));
      expect(auth.notifier.state.isAuthenticated, isFalse);
      verify(auth.authService.clearRemoteAuthentication).called(1);
      verify(auth.widgetService.clearCredentialsAndRefresh).called(1);
      expect(auth.apiGraph.purgeCalls, 1);
    });

    test('serializes concurrent unauthorized bootstraps and leaves authentication cleared', () async {
      final auth = _LoginFixture();
      var refreshCalls = 0;
      when(auth.userService.refreshMyUser).thenAnswer((_) async {
        refreshCalls++;
        throw ApiException(401, 'Unauthorized $refreshCalls');
      });

      final first = auth.notifier.login('first@test', 'password');
      final second = auth.notifier.login('second@test', 'password');

      await expectLater(first, throwsA(isA<ApiException>().having((error) => error.code, 'code', 401)));
      await expectLater(second, throwsA(isA<ApiException>().having((error) => error.code, 'code', 401)));
      expect(refreshCalls, 2);
      expect(auth.notifier.state.isAuthenticated, isFalse);
      expect(auth.shareActivations, 0);
      verify(auth.authService.clearRemoteAuthentication).called(2);
    });

    test('publishes shares and authenticated state only after a fresh user and native context succeed', () async {
      final auth = _LoginFixture();
      when(auth.userService.refreshMyUser).thenAnswer((_) async => UserStub.admin);

      final response = await auth.notifier.login('user@test', 'password');

      expect(response.accessToken, 'password-token');
      expect(auth.notifier.state.isAuthenticated, isTrue);
      expect(auth.notifier.state.userId, UserStub.admin.id);
      expect(auth.shareActivations, 1);
      expect(auth.shareSuspensions, 0);
      expect(auth.widgetCredentialWrites, 1);
      expect(auth.requestContext.installs.single.canonicalOrigin, Uri.parse('https://photos.example.test'));
      expect(auth.requestContext.installs.single.schemePolicy, EndpointSchemePolicy.httpsOnly);
      expect(auth.persistedAccessToken, 'password-token');
      expect(auth.phases.last, RemoteAuthenticationPhase.authenticated);
    });

    test('logout wins a race with login without publishing stale authenticated state', () async {
      final auth = _LoginFixture();
      final remoteLogin = Completer<LoginResponse>();
      when(() => auth.authService.login(any(), any())).thenAnswer((_) => remoteLogin.future);
      when(auth.userService.refreshMyUser).thenAnswer((_) async => UserStub.admin);

      final login = auth.notifier.login('user@test', 'password');
      await pumpEventQueue();
      final logout = auth.notifier.logout();
      remoteLogin.complete(_loginResponse);

      await expectLater(login, throwsA(isA<AuthenticationMutationCancelledException>()));
      await logout;
      expect(auth.notifier.state.isAuthenticated, isFalse);
      expect(auth.shareActivations, 0);
      expect(auth.widgetCredentialWrites, 0);
      expect(auth.requestContext.installs, isEmpty);
      expect(auth.persistedTokens, isEmpty);
      verifyNever(auth.userService.refreshMyUser);
    });
  });

  group('AuthNotifier.logout', () {
    test('cancels remote work and clears only remote authentication', () async {
      var remoteCancellationCalls = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        cancelRemoteMedia: () async => remoteCancellationCalls++,
      );

      await auth.notifier.logout();

      expect(remoteCancellationCalls, 1);
      verify(auth.authService.clearRemoteAuthentication).called(1);
    });

    test('persists the session tombstone before cancellation or remote side effects', () async {
      final events = <String>[];
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        persistSessionReadiness: (ready) async => events.add('readiness:$ready'),
        invalidateSession: () async => events.add('reachability.cancel'),
        cancelRemoteMedia: () async => events.add('remote-media.cancel'),
        suspendRemoteShares: () async => events.add('shares.suspend'),
        onRemoteLogout: () => events.add('remote.logout'),
      );

      await auth.notifier.logout();

      expect(events.first, 'readiness:false');
      expect(
        events,
        containsAllInOrder([
          'readiness:false',
          'shares.suspend',
          'reachability.cancel',
          'remote-media.cancel',
          'remote.logout',
        ]),
      );
    });

    test('tombstone write failure blocks the context and starts no cancellation or remote work', () async {
      final failure = StateError('tombstone unavailable');
      var sideEffects = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        persistSessionReadiness: (_) async => throw failure,
        invalidateSession: () async => sideEffects++,
        cancelRemoteMedia: () async => sideEffects++,
        suspendRemoteShares: () async => sideEffects++,
        cancelShares: () async => sideEffects++,
        stopBackup: () => sideEffects++,
        disconnectWebsocket: () => sideEffects++,
      );

      await expectLater(auth.notifier.logout(), throwsA(same(failure)));

      expect(auth.requestContext.blocked, isTrue);
      expect(sideEffects, 0);
      verifyNever(auth.authService.invalidateRemoteSession);
      verifyNever(auth.authService.clearRemoteAuthentication);
      verifyNever(auth.backgroundUploads.cancel);
      verifyNever(auth.foregroundUploads.cancel);
    });

    test('cancels active shares before clearing the session', () async {
      final events = <String>[];
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        cancelShares: () async => events.add('share.cancelAll'),
        onRemoteLogout: () => events.add('remote.logout'),
      );

      await auth.notifier.logout();

      expect(events, containsAllInOrder(['share.cancelAll', 'remote.logout']));
    });

    test('invalidates reachability before waiting for the session mutation mutex', () async {
      final mutex = SessionMutationMutex();
      final mutexEntered = Completer<void>();
      final releaseMutex = Completer<void>();
      final heldMutation = mutex.protect(() async {
        mutexEntered.complete();
        await releaseMutex.future;
      });
      await mutexEntered.future;
      var invalidationCalls = 0;
      final auth = _LogoutFixture(
        mutex: mutex,
        invalidateSession: () async {
          invalidationCalls++;
        },
      );

      final logout = auth.notifier.logout();
      await pumpEventQueue();

      expect(invalidationCalls, 1);
      verifyNever(auth.authService.invalidateRemoteSession);

      releaseMutex.complete();
      await Future.wait([heldMutation, logout]);
      verify(auth.authService.invalidateRemoteSession).called(1);
    });

    test('runs mutex-protected cleanup after coordinator cancellation fails', () async {
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        invalidateSession: () async => throw StateError('cancel failed'),
      );

      await expectLater(auth.notifier.logout(), throwsA(isA<StateError>()));

      verify(auth.authService.invalidateRemoteSession).called(1);
      verify(auth.widgetService.clearCredentialsAndRefresh).called(1);
      expect(auth.notifier.state.isAuthenticated, isFalse);
    });

    test('reports clearedWithWarning when auxiliary cancellation fails after credentials are cleared', () async {
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        invalidateSession: () async => throw StateError('cancel failed'),
      );

      final outcome = await auth.notifier.logoutWithOutcome();

      expect(outcome, isA<LogoutClearedWithWarning>());
      expect(outcome.didClearSession, isTrue);
      expect(auth.notifier.state.isAuthenticated, isFalse);
      verify(auth.authService.clearRemoteAuthentication).called(1);
    });

    test('cancels remote media exactly once and still clears authentication when cancellation fails', () async {
      var remoteCancellationCalls = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        cancelRemoteMedia: () async {
          remoteCancellationCalls++;
          throw StateError('remote media cancel failed');
        },
      );

      await expectLater(auth.notifier.logout(), throwsA(isA<StateError>()));

      expect(remoteCancellationCalls, 1);
      verify(auth.authService.invalidateRemoteSession).called(1);
      verify(auth.authService.clearRemoteAuthentication).called(1);
      expect(auth.notifier.state.isAuthenticated, isFalse);
    });

    test('stops persistent backup and websocket after a completed reconciliation', () async {
      var backupStops = 0;
      var websocketDisconnects = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        stopBackup: () => backupStops++,
        disconnectWebsocket: () => websocketDisconnects++,
      );

      await auth.notifier.logout();

      expect(backupStops, 1);
      expect(websocketDisconnects, 1);
      expect(auth.apiGraph.purgeCalls, 1);
      expect(auth.notifier.state.isAuthenticated, isFalse);
    });

    test('coalesces concurrent logout calls into one invalidation and cleanup', () async {
      final invalidationGate = Completer<void>();
      var invalidationCalls = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        invalidateSession: () {
          invalidationCalls++;
          return invalidationGate.future;
        },
      );

      final first = auth.notifier.logout();
      final second = auth.notifier.logout();
      expect(identical(first, second), isTrue);
      invalidationGate.complete();
      await Future.wait([first, second]);

      expect(invalidationCalls, 1);
      verify(auth.authService.invalidateRemoteSession).called(1);
    });

    test('keeps authenticated state and requests blocked until every cleanup completes', () async {
      final authService = _MockAuthService();
      final secureStorage = _MockSecureStorageService();
      final widgetService = _MockWidgetService();
      final backgroundUploads = _MockBackgroundUploadService();
      final foregroundUploads = _MockForegroundUploadService();
      final ref = _MockRef();
      final events = <String>[];
      final requestContext = _RecordingAuthRequestContext(events);
      final widgetGate = Completer<void>();
      final widgetClearStarted = Completer<void>();
      final reader = _authenticatedSessionReader();
      when(() => secureStorage.delete(any())).thenAnswer((_) async {});
      when(authService.invalidateRemoteSession).thenAnswer((_) async => events.add('remote.logout'));
      when(authService.clearRemoteAuthentication).thenAnswer((_) async {});
      when(widgetService.clearCredentialsAndRefresh).thenAnswer((_) async {
        widgetClearStarted.complete();
        await widgetGate.future;
      });
      when(backgroundUploads.cancel).thenAnswer((_) async => 0);
      when(foregroundUploads.cancel).thenReturn(null);
      when(() => ref.read(backgroundUploadServiceProvider)).thenReturn(backgroundUploads);
      when(() => ref.read(foregroundUploadServiceProvider)).thenReturn(foregroundUploads);
      final notifier = AuthNotifier(
        authService,
        _MockApiService(),
        _MockUserService(),
        secureStorage,
        widgetService,
        requestContext,
        _RecordingAuthApiGraph(events),
        SessionMutationMutex(),
        ref,
        anonymousServerDiscovery: _MockAnonymousServerDiscovery(),
        serverEndpointInstaller: _MockResolvedServerEndpointInstaller(),
        cachedSessionReader: reader,
        invalidateSession: () async {},
        cancelRemoteMedia: () async {},
        stopBackup: () {},
        disconnectWebsocket: () {},
        persistSessionReadiness: (_) async {},
      );
      notifier.hydrateCachedSession();

      final logout = notifier.logout();
      await Future.wait([widgetClearStarted.future, requestContext.purgeCompleted.future]);

      expect(requestContext.blocked, isTrue);
      expect(notifier.state.isAuthenticated, isTrue);
      expect(events, containsAllInOrder(['network.block', 'remote.logout', 'graph.purge', 'network.purge']));

      widgetGate.complete();
      await logout;

      expect(requestContext.blocked, isFalse);
      expect(notifier.state.isAuthenticated, isFalse);
      verify(backgroundUploads.cancel).called(1);
      verify(foregroundUploads.cancel).called(1);
      verify(widgetService.clearCredentialsAndRefresh).called(1);
    });

    test('keeps authenticated state blocked and surfaces native clear failure', () async {
      final authService = _MockAuthService();
      final secureStorage = _MockSecureStorageService();
      final widgetService = _MockWidgetService();
      final backgroundUploads = _MockBackgroundUploadService();
      final foregroundUploads = _MockForegroundUploadService();
      final ref = _MockRef();
      final requestContext = _RecordingAuthRequestContext(<String>[])..purgeError = StateError('native clear failed');
      when(() => secureStorage.delete(any())).thenAnswer((_) async {});
      when(authService.invalidateRemoteSession).thenAnswer((_) async {});
      when(authService.clearRemoteAuthentication).thenAnswer((_) async {});
      when(widgetService.clearCredentialsAndRefresh).thenAnswer((_) async {});
      when(backgroundUploads.cancel).thenAnswer((_) async => 0);
      when(foregroundUploads.cancel).thenReturn(null);
      when(() => ref.read(backgroundUploadServiceProvider)).thenReturn(backgroundUploads);
      when(() => ref.read(foregroundUploadServiceProvider)).thenReturn(foregroundUploads);
      final notifier = AuthNotifier(
        authService,
        _MockApiService(),
        _MockUserService(),
        secureStorage,
        widgetService,
        requestContext,
        _RecordingAuthApiGraph(<String>[]),
        SessionMutationMutex(),
        ref,
        anonymousServerDiscovery: _MockAnonymousServerDiscovery(),
        serverEndpointInstaller: _MockResolvedServerEndpointInstaller(),
        cachedSessionReader: _authenticatedSessionReader(),
        invalidateSession: () async {},
        cancelRemoteMedia: () async {},
        stopBackup: () {},
        disconnectWebsocket: () {},
        persistSessionReadiness: (_) async {},
      );
      notifier.hydrateCachedSession();

      await expectLater(notifier.logout(), throwsA(isA<StateError>()));

      expect(requestContext.blocked, isTrue);
      expect(notifier.state.isAuthenticated, isTrue);
    });

    test('keeps requests blocked when API graph purge fails', () async {
      final auth = _LogoutFixture(mutex: SessionMutationMutex(), apiGraphPurgeError: StateError('graph purge failed'));

      await expectLater(auth.notifier.logout(), throwsA(isA<StateError>()));

      expect(auth.requestContext.blocked, isTrue);
      expect(auth.notifier.state.isAuthenticated, isTrue);
      expect(auth.apiGraph.purgeCalls, 1);
    });

    test('keeps requests blocked when local Store cleanup fails while purging every other surface', () async {
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        localSessionClearError: StateError('Store cleanup failed'),
      );

      await expectLater(auth.notifier.logout(), throwsA(isA<StateError>()));

      expect(auth.requestContext.blocked, isTrue);
      expect(auth.notifier.state.isAuthenticated, isTrue);
      expect(auth.apiGraph.purgeCalls, 1);
      verify(auth.widgetService.clearCredentialsAndRefresh).called(1);
    });

    test('waits for an activation holding the shared session mutation mutex', () async {
      final mutex = SessionMutationMutex();
      final activationPaused = Completer<void>();
      final resumeActivation = Completer<void>();
      final session = _MutableActivationSession();
      final activation = _ActivationFixture(
        mutex: mutex,
        session: session,
        checkpoint: (step) async {
          if (step == EndpointActivationStep.nativeContext) {
            activationPaused.complete();
            await resumeActivation.future;
          }
        },
      );
      final auth = _LogoutFixture(mutex: mutex);

      final activationOperation = activation.adapter.activate(activation.request());
      await activationPaused.future;
      final logout = auth.notifier.logout();
      await Future<void>.delayed(Duration.zero);

      verifyNever(auth.backgroundUploads.cancel);
      verifyNever(auth.authService.invalidateRemoteSession);

      resumeActivation.complete();
      expect(await activationOperation.result, isA<OfflineSuccess<EndpointActivationReceipt>>());
      await logout;

      verify(auth.authService.invalidateRemoteSession).called(1);
      expect(auth.requestContext.blocked, isFalse);
    });

    test('rejects an activation queued after logout without publishing credentials', () async {
      final mutex = SessionMutationMutex();
      final session = _MutableActivationSession();
      final auth = _LogoutFixture(mutex: mutex, onRemoteLogout: () => session.sessionEpoch++);
      final activation = _ActivationFixture(mutex: mutex, session: session);
      final requestFromLoggedInSession = activation.request();

      await auth.notifier.logout();
      final result = await activation.adapter.activate(requestFromLoggedInSession).result;

      expect(result, const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled));
      verifyNever(() => activation.nativeContext.replace(any()));
      verifyNever(() => activation.widgetCredentials.write(any()));
      verifyNever(() => activation.endpointStore.write(any()));
      verifyNever(() => activation.apiGraph.prepare(any()));
    });
  });

  group('AuthNotifier.requireReauthentication', () {
    test('suspends remote shares after the durable tombstone without strongly cancelling local shares', () async {
      final releaseInvalidation = Completer<void>();
      var remoteSharesSuspended = false;
      var strongShareCancellations = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        suspendRemoteShares: () {
          remoteSharesSuspended = true;
          return Future.value();
        },
        cancelShares: () async => strongShareCancellations++,
        invalidateSession: () => releaseInvalidation.future,
      );

      final termination = auth.notifier.requireReauthentication();

      expect(remoteSharesSuspended, isFalse);
      await pumpEventQueue();
      expect(remoteSharesSuspended, isTrue);
      expect(strongShareCancellations, 0);
      releaseInvalidation.complete();
      await termination;
      expect(strongShareCancellations, 0);
    });

    test('invalidates only operational remote credentials and publishes the reauthentication state', () async {
      final phases = <RemoteAuthenticationPhase>[];
      final auth = _LogoutFixture(mutex: SessionMutationMutex(), publishRemoteAuthenticationPhase: phases.add);

      await auth.notifier.requireReauthentication();

      verifyNever(auth.authService.invalidateRemoteSession);
      verify(auth.authService.clearRemoteAuthentication).called(1);
      verify(auth.widgetService.clearCredentialsAndRefresh).called(1);
      expect(auth.apiGraph.purgeCalls, 1);
      expect(auth.notifier.state.isAuthenticated, isFalse);
      expect(phases, [RemoteAuthenticationPhase.authenticated, RemoteAuthenticationPhase.reauthenticationRequired]);
    });

    test('blocks requests before waiting for remote cancellation', () async {
      final cancellationStarted = Completer<void>();
      final releaseCancellation = Completer<void>();
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        cancelRemoteMedia: () async {
          cancellationStarted.complete();
          await releaseCancellation.future;
        },
      );

      final operation = auth.notifier.requireReauthentication();
      await cancellationStarted.future;

      expect(auth.requestContext.blocked, isTrue);
      releaseCancellation.complete();
      await operation;
    });

    test('escalates reauthentication to one remote logout when logout arrives during cancellation', () async {
      final cancellationStarted = Completer<void>();
      final releaseCancellation = Completer<void>();
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        cancelRemoteMedia: () async {
          cancellationStarted.complete();
          await releaseCancellation.future;
        },
      );

      final reauthentication = auth.notifier.requireReauthentication();
      await cancellationStarted.future;
      final logout = auth.notifier.logout();
      releaseCancellation.complete();
      await Future.wait([reauthentication, logout]);

      verify(auth.authService.invalidateRemoteSession).called(1);
    });

    test('coalesces duplicate reauthentication requests without remote logout', () async {
      final cancellationStarted = Completer<void>();
      final releaseCancellation = Completer<void>();
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        cancelRemoteMedia: () async {
          cancellationStarted.complete();
          await releaseCancellation.future;
        },
      );

      final first = auth.notifier.requireReauthentication();
      final second = auth.notifier.requireReauthentication();
      expect(identical(first, second), isTrue);
      await cancellationStarted.future;
      releaseCancellation.complete();
      await Future.wait([first, second]);

      verifyNever(auth.authService.invalidateRemoteSession);
      verify(auth.authService.clearRemoteAuthentication).called(1);
    });

    test('applies a late logout escalation before completing the shared future', () async {
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      var strongShareCancellations = 0;
      final auth = _LogoutFixture(mutex: SessionMutationMutex(), cancelShares: () async => strongShareCancellations++);
      when(auth.authService.clearRemoteAuthentication).thenAnswer((_) async {
        cleanupStarted.complete();
        await releaseCleanup.future;
      });

      final reauthentication = auth.notifier.requireReauthentication();
      await cleanupStarted.future;
      final logout = auth.notifier.logout();
      releaseCleanup.complete();
      await Future.wait([reauthentication, logout]);

      verify(auth.authService.invalidateRemoteSession).called(1);
      verify(auth.authService.clearRemoteAuthentication).called(1);
      expect(strongShareCancellations, 1);
    });

    test('applies a late forget escalation and publishes unconfigured before completing', () async {
      final cleanupStarted = Completer<void>();
      final releaseCleanup = Completer<void>();
      final phases = <RemoteAuthenticationPhase>[];
      var strongShareCancellations = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        publishRemoteAuthenticationPhase: phases.add,
        cancelShares: () async => strongShareCancellations++,
      );
      when(auth.authService.clearRemoteAuthentication).thenAnswer((_) async {
        cleanupStarted.complete();
        await releaseCleanup.future;
      });

      final reauthentication = auth.notifier.requireReauthentication();
      await cleanupStarted.future;
      final forget = auth.notifier.forgetServer();
      releaseCleanup.complete();
      await Future.wait([reauthentication, forget]);

      verify(auth.authService.invalidateRemoteSession).called(1);
      verify(auth.authService.forgetServer).called(1);
      expect(strongShareCancellations, 1);
      expect(phases.last, RemoteAuthenticationPhase.unconfigured);
    });

    test('runs a logout queued after cutover even when the preceding reauthentication fails', () async {
      final cutoverReached = Completer<void>();
      final releaseFirstCleanup = Completer<void>();
      final auth = _LogoutFixture(mutex: SessionMutationMutex());
      var authenticationClearCalls = 0;
      var widgetClearCalls = 0;
      when(auth.authService.clearRemoteAuthentication).thenAnswer((_) async {
        authenticationClearCalls++;
        if (authenticationClearCalls == 1) {
          throw StateError('reauthentication cleanup failed');
        }
      });
      when(auth.widgetService.clearCredentialsAndRefresh).thenAnswer((_) async {
        widgetClearCalls++;
        if (widgetClearCalls == 1) {
          cutoverReached.complete();
          await releaseFirstCleanup.future;
        }
      });

      final reauthentication = auth.notifier.requireReauthentication();
      await cutoverReached.future;
      final logout = auth.notifier.logout();
      releaseFirstCleanup.complete();

      await expectLater(reauthentication, throwsA(isA<StateError>()));
      await logout;
      verify(auth.authService.invalidateRemoteSession).called(1);
      expect(authenticationClearCalls, 2);
    });

    test('runs a queued forget and reports both cleanup failures', () async {
      final cutoverReached = Completer<void>();
      final releaseFirstCleanup = Completer<void>();
      final firstFailure = StateError('reauthentication cleanup failed');
      final secondFailure = StateError('forget cleanup failed');
      final auth = _LogoutFixture(mutex: SessionMutationMutex());
      when(auth.authService.clearRemoteAuthentication).thenThrow(firstFailure);
      when(auth.authService.forgetServer).thenThrow(secondFailure);
      var widgetClearCalls = 0;
      when(auth.widgetService.clearCredentialsAndRefresh).thenAnswer((_) async {
        widgetClearCalls++;
        if (widgetClearCalls == 1) {
          cutoverReached.complete();
          await releaseFirstCleanup.future;
        }
      });

      final reauthentication = auth.notifier.requireReauthentication();
      await cutoverReached.future;
      final forget = auth.notifier.forgetServer();
      releaseFirstCleanup.complete();

      await expectLater(reauthentication, throwsA(same(firstFailure)));
      await expectLater(
        forget,
        throwsA(
          isA<RemoteAuthenticationTerminationSequenceException>()
              .having((error) => error.precedingError, 'precedingError', same(firstFailure))
              .having((error) => error.queuedError, 'queuedError', same(secondFailure)),
        ),
      );
      verify(auth.authService.forgetServer).called(1);
    });
  });

  group('AuthNotifier.forgetServer', () {
    test('purges the configured remote session and publishes unconfigured without touching local media', () async {
      final phases = <RemoteAuthenticationPhase>[];
      var epochInvalidations = 0;
      var remoteCancellations = 0;
      var shareCancellations = 0;
      var backupStops = 0;
      var websocketDisconnects = 0;
      final auth = _LogoutFixture(
        mutex: SessionMutationMutex(),
        publishRemoteAuthenticationPhase: phases.add,
        invalidateSession: () async => epochInvalidations++,
        cancelRemoteMedia: () async => remoteCancellations++,
        cancelShares: () async => shareCancellations++,
        stopBackup: () => backupStops++,
        disconnectWebsocket: () => websocketDisconnects++,
      );

      await auth.notifier.forgetServer();

      expect(epochInvalidations, 1);
      expect(remoteCancellations, 1);
      expect(shareCancellations, 1);
      expect(backupStops, 1);
      expect(websocketDisconnects, 1);
      verify(auth.authService.invalidateRemoteSession).called(1);
      verify(auth.authService.forgetServer).called(1);
      verifyNever(auth.authService.clearRemoteAuthentication);
      verify(auth.widgetService.clearCredentialsAndRefresh).called(1);
      expect(auth.apiGraph.purgeCalls, 1);
      expect(auth.notifier.state.isAuthenticated, isFalse);
      expect(phases, [RemoteAuthenticationPhase.authenticated, RemoteAuthenticationPhase.unconfigured]);
    });
  });
}

_MockCachedSessionReader _authenticatedSessionReader() {
  final reader = _MockCachedSessionReader();
  when(reader.read).thenReturn(
    CachedSession(
      accessToken: 'cached-token',
      apiEndpoint: Uri.parse('https://photos.example.test/api'),
      user: UserStub.admin,
      deviceId: 'cached-device',
    ),
  );
  return reader;
}

final class _RecordingAuthRequestContext implements AuthRequestContextPort {
  _RecordingAuthRequestContext(this.events);

  final List<String> events;
  var blocked = false;
  Object? purgeError;
  final purgeCompleted = Completer<void>();
  final installs = <({Uri canonicalOrigin, String accessToken, EndpointSchemePolicy schemePolicy})>[];

  @override
  void block() {
    events.add('network.block');
    blocked = true;
  }

  @override
  Future<void> install({
    required Uri canonicalOrigin,
    required String accessToken,
    required EndpointSchemePolicy schemePolicy,
    required Map<String, String> customHeaders,
  }) async {
    events.add('network.install');
    installs.add((canonicalOrigin: canonicalOrigin, accessToken: accessToken, schemePolicy: schemePolicy));
  }

  @override
  Future<void> purge() async {
    events.add('network.purge');
    if (purgeError case final error?) throw error;
    if (!purgeCompleted.isCompleted) purgeCompleted.complete();
  }

  @override
  void publishCleared() {
    events.add('network.publishCleared');
    blocked = false;
  }
}

final class _RecordingAuthApiGraph implements AuthApiGraphPort {
  _RecordingAuthApiGraph(this.events);

  final List<String> events;
  Object? purgeError;
  int purgeCalls = 0;

  @override
  Future<void> purge() async {
    purgeCalls++;
    events.add('graph.purge');
    if (purgeError case final error?) {
      throw error;
    }
  }
}

final class _LogoutFixture {
  _LogoutFixture({
    required SessionMutationMutex mutex,
    AnonymousServerDiscoveryPort? anonymousServerDiscovery,
    ResolvedServerEndpointInstallerPort? serverEndpointInstaller,
    Uri? Function()? readConfiguredEndpoint,
    void Function()? onRemoteLogout,
    Future<void> Function()? invalidateSession,
    Future<void> Function()? cancelRemoteMedia,
    Future<void> Function()? suspendRemoteShares,
    Future<void> Function()? cancelShares,
    void Function()? activateShares,
    void Function()? stopBackup,
    void Function()? disconnectWebsocket,
    void Function(RemoteAuthenticationPhase)? publishRemoteAuthenticationPhase,
    Object? apiGraphPurgeError,
    Object? localSessionClearError,
    Future<void> Function(bool)? persistSessionReadiness,
  }) {
    apiGraph.purgeError = apiGraphPurgeError;
    when(() => secureStorage.delete(any())).thenAnswer((_) async {});
    when(authService.invalidateRemoteSession).thenAnswer((_) async => onRemoteLogout?.call());
    when(authService.forgetServer).thenAnswer((_) async {});
    when(authService.clearRemoteAuthentication).thenAnswer((_) async {
      if (localSessionClearError case final error?) {
        throw error;
      }
    });
    when(widgetService.clearCredentialsAndRefresh).thenAnswer((_) async {});
    when(backgroundUploads.cancel).thenAnswer((_) async => 0);
    when(foregroundUploads.cancel).thenReturn(null);
    when(() => ref.read(backgroundUploadServiceProvider)).thenReturn(backgroundUploads);
    when(() => ref.read(foregroundUploadServiceProvider)).thenReturn(foregroundUploads);
    notifier = AuthNotifier(
      authService,
      _MockApiService(),
      _MockUserService(),
      secureStorage,
      widgetService,
      requestContext,
      apiGraph,
      mutex,
      ref,
      cachedSessionReader: _authenticatedSessionReader(),
      anonymousServerDiscovery: anonymousServerDiscovery ?? _MockAnonymousServerDiscovery(),
      serverEndpointInstaller: serverEndpointInstaller ?? _MockResolvedServerEndpointInstaller(),
      readConfiguredEndpoint: readConfiguredEndpoint,
      hasConfiguredServer: () => true,
      publishRemoteAuthenticationPhase: publishRemoteAuthenticationPhase,
      invalidateSession: invalidateSession ?? () async {},
      cancelRemoteMedia: cancelRemoteMedia ?? () async {},
      suspendRemoteShares: suspendRemoteShares ?? () async {},
      cancelShares: cancelShares ?? () async {},
      activateShares: activateShares ?? () {},
      stopBackup: stopBackup ?? () {},
      disconnectWebsocket: disconnectWebsocket ?? () {},
      persistSessionReadiness: persistSessionReadiness ?? (_) async {},
    );
    notifier.hydrateCachedSession();
  }

  final authService = _MockAuthService();
  final secureStorage = _MockSecureStorageService();
  final widgetService = _MockWidgetService();
  final backgroundUploads = _MockBackgroundUploadService();
  final foregroundUploads = _MockForegroundUploadService();
  final ref = _MockRef();
  final requestContext = _RecordingAuthRequestContext(<String>[]);
  final apiGraph = _RecordingAuthApiGraph(<String>[]);
  late final AuthNotifier notifier;
}

const _loginResponse = LoginResponse(
  accessToken: 'password-token',
  isAdmin: true,
  name: 'Admin',
  profileImagePath: '',
  shouldChangePassword: false,
  userEmail: 'user@test',
  userId: 'user-1',
);

final class _LoginFixture {
  _LoginFixture() {
    when(() => authService.login(any(), any())).thenAnswer((_) async => _loginResponse);
    when(authService.clearRemoteAuthentication).thenAnswer((_) async {});
    when(authService.invalidateRemoteSession).thenAnswer((_) async {});
    when(widgetService.clearCredentialsAndRefresh).thenAnswer((_) async {});
    when(() => secureStorage.delete(any())).thenAnswer((_) async {});
    when(backgroundUploads.cancel).thenAnswer((_) async => 0);
    when(foregroundUploads.cancel).thenReturn(null);
    when(() => ref.read(backgroundUploadServiceProvider)).thenReturn(backgroundUploads);
    when(() => ref.read(foregroundUploadServiceProvider)).thenReturn(foregroundUploads);
    when(cachedSessionReader.read).thenReturn(null);

    notifier = AuthNotifier(
      authService,
      apiService,
      userService,
      secureStorage,
      widgetService,
      requestContext,
      apiGraph,
      SessionMutationMutex(),
      ref,
      cachedSessionReader: cachedSessionReader,
      anonymousServerDiscovery: _MockAnonymousServerDiscovery(),
      serverEndpointInstaller: _MockResolvedServerEndpointInstaller(),
      hasConfiguredServer: () => true,
      readConfiguredEndpoint: () => Uri.parse('https://photos.example.test/immich/api'),
      readConfiguredEndpointPolicy: () => EndpointSchemePolicy.httpsOnly,
      readCustomHeaders: () => const {'x-client': 'mobile'},
      publishRemoteAuthenticationPhase: phases.add,
      invalidateSession: () async {},
      cancelRemoteMedia: () async {},
      suspendRemoteShares: () async => shareSuspensions++,
      cancelShares: () async {},
      activateShares: () => shareActivations++,
      stopBackup: () {},
      disconnectWebsocket: () {},
      persistAccessToken: (token) async {
        persistedTokens.add(token);
        persistedAccessToken = token;
      },
      clearPersistedAuthentication: () async {
        await authService.clearRemoteAuthentication();
        persistedAccessToken = null;
      },
      persistSessionReadiness: (ready) async => readinessWrites.add(ready),
      readOrCreateDeviceId: () async => 'device-1',
      persistDeviceIdentity: (_) async {},
      publishWidgetCredentials: (_) async => widgetCredentialWrites++,
    );
  }

  final authService = _MockAuthService();
  final apiService = _MockApiService();
  final userService = _MockUserService();
  final secureStorage = _MockSecureStorageService();
  final widgetService = _MockWidgetService();
  final backgroundUploads = _MockBackgroundUploadService();
  final foregroundUploads = _MockForegroundUploadService();
  final cachedSessionReader = _MockCachedSessionReader();
  final ref = _MockRef();
  final requestContext = _RecordingAuthRequestContext(<String>[]);
  final apiGraph = _RecordingAuthApiGraph(<String>[]);
  final phases = <RemoteAuthenticationPhase>[];
  final persistedTokens = <String>[];
  String? persistedAccessToken;
  final readinessWrites = <bool>[];
  var shareActivations = 0;
  var shareSuspensions = 0;
  var widgetCredentialWrites = 0;
  late final AuthNotifier notifier;
}

final class _MutableActivationSession implements ActivationSessionPort {
  var sessionEpoch = 3;

  @override
  ActivationSessionSnapshot snapshot() => ActivationSessionSnapshot(
    sessionEpoch: sessionEpoch,
    probeGeneration: 7,
    userId: 'cached-user',
    accessToken: 'current-token',
    customHeaders: const {},
  );
}

final class _ActivationFixture {
  _ActivationFixture({
    required SessionMutationMutex mutex,
    required _MutableActivationSession session,
    EndpointActivationCheckpoint? checkpoint,
  }) {
    when(() => apiGraph.currentEndpoint).thenReturn(Uri.parse('https://old.test/api'));
    when(() => apiGraph.prepare(any())).thenAnswer((_) async => preparedGraph);
    when(() => apiGraph.install(preparedGraph)).thenAnswer((_) async {});
    when(nativeContext.snapshot).thenReturn(
      NativeRequestContext(
        canonicalOrigin: Uri.parse('https://old.test'),
        accessToken: 'old-token',
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        customHeaders: const {},
      ),
    );
    when(() => nativeContext.replace(any())).thenAnswer((_) async {});
    when(endpointStore.read).thenReturn(
      ConfirmedServerEndpoint(
        apiEndpoint: Uri.parse('https://old.test/api'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
      ),
    );
    when(() => endpointStore.write(any())).thenAnswer((_) async {});
    when(widgetCredentials.snapshot).thenAnswer(
      (_) async => const WidgetCredentials(apiEndpoint: null, accessToken: 'old-token', customHeaders: null),
    );
    when(() => widgetCredentials.write(any())).thenAnswer((_) async {});
    adapter = EndpointActivationAdapter(
      mutex: mutex,
      session: session,
      apiGraph: apiGraph,
      nativeContext: nativeContext,
      requestContextLease: const _NoopRequestContextLease(),
      endpointStore: endpointStore,
      widgetCredentials: widgetCredentials,
      checkpoint: checkpoint,
    );
  }

  final apiGraph = _MockEndpointApiGraph();
  final nativeContext = _MockNativeRequestContext();
  final endpointStore = _MockConfirmedEndpointStore();
  final widgetCredentials = _MockWidgetCredentials();
  final preparedGraph = _PreparedApiGraph();
  late final EndpointActivationAdapter adapter;

  EndpointActivationRequest request() => EndpointActivationRequest(
    endpoint: ValidatedEndpointProbeResult(
      canonicalOrigin: Uri.parse('https://photos.test'),
      apiEndpoint: Uri.parse('https://photos.test/api'),
      userId: 'cached-user',
      schemePolicy: EndpointSchemePolicy.httpsOnly,
    ),
    sessionEpoch: 3,
    probeGeneration: 7,
  );
}

final class _NoopRequestContextLease implements RequestContextLeasePort {
  const _NoopRequestContextLease();

  @override
  RequestContextActivationLease? beginActivation(EndpointSchemePolicy policy) => null;

  @override
  bool commitActivation(RequestContextActivationLease lease) => false;

  @override
  bool isCurrent(RequestContextActivationLease lease) => false;

  @override
  void abandonActivation(RequestContextActivationLease lease) {}

  @override
  bool invalidateForTransportReview() => false;

  @override
  void invalidateAfterValidationFailure() {}
}
