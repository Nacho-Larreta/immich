import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:mocktail/mocktail.dart';

class _MockRemoteAlbumService extends Mock implements RemoteAlbumService {}

class _MockUserService extends Mock implements UserService {}

class _MockRemoteAlbum extends Mock implements RemoteAlbum {}

void main() {
  late _MockRemoteAlbumService albumService;
  late _MockUserService userService;

  setUp(() {
    albumService = _MockRemoteAlbumService();
    userService = _MockUserService();
    when(() => userService.tryGetMyUser()).thenReturn(null);
    when(() => userService.watchMyUser()).thenAnswer((_) => const Stream<UserDto?>.empty());
  });

  test('remote mutation is rejected without calling the service unless access is online', () async {
    final offline = ProviderContainer(
      overrides: [
        remoteAlbumServiceProvider.overrideWithValue(albumService),
        userServiceProvider.overrideWithValue(userService),
        serverAccessProvider.overrideWithValue(const ServerAccessPolicy.offline()),
      ],
    );
    addTearDown(offline.dispose);

    await expectLater(offline.read(remoteAlbumProvider.notifier).deleteAlbum('album-id'), throwsA(isA<StateError>()));
    verifyNever(() => albumService.deleteAlbum(any()));

    when(() => albumService.deleteAlbum('album-id')).thenAnswer((_) async {});
    final online = ProviderContainer(
      overrides: [
        remoteAlbumServiceProvider.overrideWithValue(albumService),
        userServiceProvider.overrideWithValue(userService),
        serverAccessProvider.overrideWithValue(const ServerAccessPolicy.online()),
      ],
    );
    addTearDown(online.dispose);

    await online.read(remoteAlbumProvider.notifier).deleteAlbum('album-id');
    verify(() => albumService.deleteAlbum('album-id')).called(1);
  });

  test('add-to-album is rejected during reauthentication without calling the service', () async {
    final container = ProviderContainer(
      overrides: [
        remoteAlbumServiceProvider.overrideWithValue(albumService),
        userServiceProvider.overrideWithValue(userService),
        serverAccessProvider.overrideWithValue(const ServerAccessPolicy.reauthenticationRequired()),
      ],
    );
    addTearDown(container.dispose);

    expect(
      () => container.read(remoteAlbumProvider.notifier).addAssets('album-id', const ['asset-id']),
      throwsA(isA<StateError>()),
    );
    verifyNever(
      () => albumService.addAssets(
        albumId: any(named: 'albumId'),
        assetIds: any(named: 'assetIds'),
      ),
    );
  });

  test('refresh completion from a previous viewer cannot replace the current viewer albums', () async {
    final viewerScope = StateProvider<RemoteViewerScope?>(
      (_) => const RemoteViewerScope(viewerId: 'A', sessionEpoch: 1),
    );
    final albumsForA = Completer<List<RemoteAlbum>>();
    final albumsForB = Completer<List<RemoteAlbum>>();
    final albumA = _MockRemoteAlbum();
    final albumB = _MockRemoteAlbum();
    when(() => albumService.getAll('A')).thenAnswer((_) => albumsForA.future);
    when(() => albumService.getAll('B')).thenAnswer((_) => albumsForB.future);

    final container = ProviderContainer(
      overrides: [
        remoteAlbumServiceProvider.overrideWithValue(albumService),
        userServiceProvider.overrideWithValue(userService),
        serverAccessProvider.overrideWithValue(const ServerAccessPolicy.online()),
        remoteViewerScopeProvider.overrideWith((ref) => ref.watch(viewerScope)),
      ],
    );
    addTearDown(container.dispose);

    final refreshA = container.read(remoteAlbumProvider.notifier).refresh();
    container.read(viewerScope.notifier).state = const RemoteViewerScope(viewerId: 'B', sessionEpoch: 2);
    final refreshB = container.read(remoteAlbumProvider.notifier).refresh();
    albumsForB.complete([albumB]);
    await refreshB;
    expect(container.read(remoteAlbumProvider).albums, [albumB]);

    albumsForA.complete([albumA]);
    await refreshA;
    expect(container.read(remoteAlbumProvider).albums, [albumB]);
  });

  test('current album re-resolves membership for the scoped viewer instead of exposing a route argument', () async {
    const scope = RemoteAlbumScope(
      viewer: RemoteViewerScope(viewerId: 'B', sessionEpoch: 2),
      albumId: 'album',
    );
    when(() => albumService.watchAlbum('album', 'B')).thenAnswer((_) => Stream.value(null));
    final container = ProviderContainer(
      overrides: [
        remoteAlbumServiceProvider.overrideWithValue(albumService),
        currentRemoteAlbumScopedProvider.overrideWithValue(scope),
      ],
    );
    addTearDown(container.dispose);

    final subscription = container.listen(currentRemoteAlbumProvider, (_, _) {}, fireImmediately: true);
    addTearDown(subscription.close);
    await pumpEventQueue();

    expect(container.read(currentRemoteAlbumProvider), isNull);
    verify(() => albumService.watchAlbum('album', 'B')).called(1);
  });
}
