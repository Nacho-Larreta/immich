import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/providers/auth.provider.dart';
import 'package:immich_mobile/providers/cached_session.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:immich_mobile/services/widget.service.dart';
import 'package:mocktail/mocktail.dart';

import '../fixtures/user.stub.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockAuthService extends Mock implements AuthService {}

class _MockCachedSessionReader extends Mock implements CachedSessionReader {}

class _MockRef extends Mock implements Ref {}

class _MockSecureStorageService extends Mock implements SecureStorageService {}

class _MockUserService extends Mock implements UserService {}

class _MockWidgetService extends Mock implements WidgetService {}

void main() {
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
      verifyNever(() => widgetService.writeCredentials(any(), any(), any()));
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
        _MockRef(),
        cachedSessionReader: reader,
      );

      expect(notifier.hydrateCachedSession(), isFalse);
      expect(notifier.state.isAuthenticated, isFalse);
    });
  });
}
