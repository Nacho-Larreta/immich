import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/services/session_mutation_mutex.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/cached_session.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';

import '../fixtures/user.stub.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockAuthService extends Mock implements AuthService {}

class _MockBackgroundUploadService extends Mock implements BackgroundUploadService {}

class _MockCachedSessionReader extends Mock implements CachedSessionReader {}

class _MockRef extends Mock implements Ref {}

class _MockForegroundUploadService extends Mock implements ForegroundUploadService {}

class _MockSecureStorageService extends Mock implements SecureStorageService {}

class _MockUserService extends Mock implements UserService {}

class _MockWidgetService extends Mock implements WidgetService {}

class _MockEndpointApiGraph extends Mock implements EndpointApiGraphPort {}

class _MockNativeRequestContext extends Mock implements NativeRequestContextPort {}

class _MockConfirmedEndpointStore extends Mock implements ConfirmedEndpointStorePort {}

class _MockWidgetCredentials extends Mock implements WidgetCredentialsPort {}

final class _PreparedApiGraph extends Fake implements PreparedApiGraph {}

void main() {
  setUpAll(() {
    registerFallbackValue(Uri.parse('https://fallback.test/api'));
    registerFallbackValue(NativeRequestContext(canonicalOrigin: null, accessToken: null, customHeaders: const {}));
    registerFallbackValue(const WidgetCredentials(apiEndpoint: null, accessToken: null, customHeaders: null));
  });

  group('AuthNotifier.hydrateCachedSession', () {
    test('publishes cached auth without remote or native side effects', () {
      final authService = _MockAuthService();
      final apiService = _MockApiService();
      final userService = _MockUserService();
      final secureStorage = _MockSecureStorageService();
      final widgetService = _MockWidgetService();
      final reader = _MockCachedSessionReader();
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
        SessionMutationMutex(),
        _MockRef(),
        cachedSessionReader: reader,
      );

      final hydrated = notifier.hydrateCachedSession();

      expect(hydrated, isTrue);
      expect(notifier.state.isAuthenticated, isTrue);
      expect(notifier.state.userId, UserStub.admin.id);
      expect(notifier.state.userEmail, UserStub.admin.email);
      expect(notifier.state.name, UserStub.admin.name);
      expect(notifier.state.isAdmin, isTrue);
      expect(notifier.state.deviceId, 'cached-device');
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
        SessionMutationMutex(),
        _MockRef(),
        cachedSessionReader: reader,
      );

      expect(notifier.hydrateCachedSession(), isFalse);
      expect(notifier.state.isAuthenticated, isFalse);
    });
  });

  group('AuthNotifier.logout', () {
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
      when(authService.logout).thenAnswer((_) async => events.add('remote.logout'));
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
        SessionMutationMutex(),
        ref,
        cachedSessionReader: reader,
      );
      notifier.hydrateCachedSession();

      final logout = notifier.logout();
      await Future.wait([widgetClearStarted.future, requestContext.purgeCompleted.future]);

      expect(requestContext.blocked, isTrue);
      expect(notifier.state.isAuthenticated, isTrue);
      expect(events, containsAllInOrder(['remote.logout', 'network.block', 'network.purge']));

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
      when(authService.logout).thenAnswer((_) async {});
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
        SessionMutationMutex(),
        ref,
        cachedSessionReader: _authenticatedSessionReader(),
      );
      notifier.hydrateCachedSession();

      await expectLater(notifier.logout(), throwsA(isA<StateError>()));

      expect(requestContext.blocked, isTrue);
      expect(notifier.state.isAuthenticated, isTrue);
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
      verifyNever(auth.authService.logout);

      resumeActivation.complete();
      expect(await activationOperation.result, isA<OfflineSuccess<EndpointActivationReceipt>>());
      await logout;

      verify(auth.authService.logout).called(1);
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

  @override
  void block() {
    events.add('network.block');
    blocked = true;
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

final class _LogoutFixture {
  _LogoutFixture({required SessionMutationMutex mutex, void Function()? onRemoteLogout}) {
    when(() => secureStorage.delete(any())).thenAnswer((_) async {});
    when(authService.logout).thenAnswer((_) async => onRemoteLogout?.call());
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
      mutex,
      ref,
      cachedSessionReader: _authenticatedSessionReader(),
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
        customHeaders: const {},
      ),
    );
    when(() => nativeContext.replace(any())).thenAnswer((_) async {});
    when(endpointStore.read).thenReturn(Uri.parse('https://old.test/api'));
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
