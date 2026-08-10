import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/routing/auth_guard.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:mocktail/mocktail.dart';
import 'package:openapi/api.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockAuthenticationApi extends Mock implements AuthenticationApi {}

class _MockNavigationResolver extends Mock implements NavigationResolver {}

class _MockStackRouter extends Mock implements StackRouter {}

void main() {
  test('auth guard presents authentication without replacing the existing shell', () async {
    final events = <String>[];
    final coordinator = AuthGuardReauthenticationCoordinator(() async => events.add('require.reauthentication'));

    await coordinator.present(() async => events.add('present.authentication'));

    expect(events, containsAll(['present.authentication', 'require.reauthentication']));
  });

  test('still requires authentication when presenting the prompt fails', () async {
    var invalidationCalls = 0;
    final coordinator = AuthGuardReauthenticationCoordinator(() async => invalidationCalls++);

    await expectLater(
      coordinator.present(() async => throw StateError('navigation failed')),
      throwsA(isA<StateError>()),
    );

    expect(invalidationCalls, 1);
  });

  test('coalesces concurrent authentication prompts', () async {
    final gate = Completer<void>();
    var presentations = 0;
    var reauthenticationCalls = 0;
    final coordinator = AuthGuardReauthenticationCoordinator(() async {
      reauthenticationCalls++;
      await gate.future;
    });

    final first = coordinator.present(() async => presentations++);
    final second = coordinator.present(() async => presentations++);
    expect(identical(first, second), isTrue);

    gate.complete();
    await Future.wait([first, second]);
    expect(presentations, 1);
    expect(reauthenticationCalls, 1);
  });

  test('waits for credential cleanup before presenting authentication', () async {
    final cleanupStarted = Completer<void>();
    final releaseCleanup = Completer<void>();
    var presentations = 0;
    final coordinator = AuthGuardReauthenticationCoordinator(() async {
      cleanupStarted.complete();
      await releaseCleanup.future;
    });

    final operation = coordinator.present(() async => presentations++);
    await cleanupStarted.future;

    expect(presentations, 0);
    releaseCleanup.complete();
    await operation;
    expect(presentations, 1);
  });

  for (final invalidAuthentication in <(String, Future<ValidateAccessTokenResponseDto?> Function())>[
    ('authStatus false', () async => ValidateAccessTokenResponseDto(authStatus: false)),
    ('401', () => Future.error(ApiException(401, 'Unauthorized'))),
  ]) {
    test('${invalidAuthentication.$1} aborts the remote route and requires authentication', () async {
      final apiService = _MockApiService();
      final authenticationApi = _MockAuthenticationApi();
      final resolver = _MockNavigationResolver();
      final router = _MockStackRouter();
      var presentations = 0;
      var reauthenticationCalls = 0;
      when(() => apiService.authenticationApi).thenReturn(authenticationApi);
      when(authenticationApi.validateAccessToken).thenAnswer((_) => invalidAuthentication.$2());
      when(() => resolver.next(any())).thenReturn(null);
      final guard = AuthGuard(
        apiService,
        () async => reauthenticationCalls++,
        readAccessToken: () => 'expired-token',
        presentAuthentication: (_) async => presentations++,
      );

      guard.onNavigation(resolver, router);
      await pumpEventQueue();

      verify(() => resolver.next(false)).called(1);
      expect(presentations, 1);
      expect(reauthenticationCalls, 1);
    });
  }
}
