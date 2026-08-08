import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/providers/cached_session.dart';
import 'package:mocktail/mocktail.dart';

import '../fixtures/user.stub.dart';

class _MockStoreService extends Mock implements StoreService {}

class _MockUserService extends Mock implements UserService {}

void main() {
  test('reads only cached authentication inputs and does not require serverUrl', () {
    final store = _MockStoreService();
    final userService = _MockUserService();
    when(() => store.tryGet(StoreKey.accessToken)).thenReturn('cached-token');
    when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn('https://photos.example.test/immich/api');
    when(() => store.tryGet(StoreKey.deviceId)).thenReturn('cached-device');
    when(userService.tryGetMyUser).thenReturn(UserStub.admin);

    final session = StoreCachedSessionReader(store, userService).read();

    expect(session?.accessToken, 'cached-token');
    expect(session?.apiEndpoint, Uri.parse('https://photos.example.test/immich/api'));
    expect(session?.deviceId, 'cached-device');
    expect(session?.user, UserStub.admin);
    verify(() => store.tryGet(StoreKey.accessToken)).called(1);
    verify(() => store.tryGet(StoreKey.serverEndpoint)).called(1);
    verify(() => store.tryGet(StoreKey.deviceId)).called(1);
    verifyNoMoreInteractions(store);
    verify(userService.tryGetMyUser).called(1);
    verifyNoMoreInteractions(userService);
  });

  test('rejects an incomplete cached session', () {
    final store = _MockStoreService();
    final userService = _MockUserService();
    when(() => store.tryGet(StoreKey.accessToken)).thenReturn('cached-token');
    when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn(null);
    when(() => store.tryGet(StoreKey.deviceId)).thenReturn(null);
    when(userService.tryGetMyUser).thenReturn(UserStub.admin);

    expect(StoreCachedSessionReader(store, userService).read(), isNull);
    _verifyReadOnlyCacheAccess(store, userService);
  });

  test('rejects an empty access token without writing to Store', () {
    final store = _MockStoreService();
    final userService = _MockUserService();
    _stubCachedSession(store, userService, accessToken: '');

    expect(StoreCachedSessionReader(store, userService).read(), isNull);
    _verifyReadOnlyCacheAccess(store, userService);
  });

  test('rejects an invalid endpoint without writing to Store', () {
    final store = _MockStoreService();
    final userService = _MockUserService();
    _stubCachedSession(store, userService, endpoint: 'not a URL');

    expect(StoreCachedSessionReader(store, userService).read(), isNull);
    _verifyReadOnlyCacheAccess(store, userService);
  });

  test('rejects a missing cached user without writing to Store', () {
    final store = _MockStoreService();
    final userService = _MockUserService();
    _stubCachedSession(store, userService, hasUser: false);

    expect(StoreCachedSessionReader(store, userService).read(), isNull);
    _verifyReadOnlyCacheAccess(store, userService);
  });
}

void _stubCachedSession(
  _MockStoreService store,
  _MockUserService userService, {
  String accessToken = 'cached-token',
  String? endpoint = 'https://photos.example.test/immich/api',
  bool hasUser = true,
}) {
  when(() => store.tryGet(StoreKey.accessToken)).thenReturn(accessToken);
  when(() => store.tryGet(StoreKey.serverEndpoint)).thenReturn(endpoint);
  when(() => store.tryGet(StoreKey.deviceId)).thenReturn(null);
  when(userService.tryGetMyUser).thenReturn(hasUser ? UserStub.admin : null);
}

void _verifyReadOnlyCacheAccess(_MockStoreService store, _MockUserService userService) {
  verify(() => store.tryGet(StoreKey.accessToken)).called(1);
  verify(() => store.tryGet(StoreKey.serverEndpoint)).called(1);
  verify(() => store.tryGet(StoreKey.deviceId)).called(1);
  verifyNoMoreInteractions(store);
  verify(userService.tryGetMyUser).called(1);
  verifyNoMoreInteractions(userService);
}
