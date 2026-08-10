import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/presentation/widgets/album/remote_album_scope_boundary.widget.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:mocktail/mocktail.dart';

class _MockRemoteAlbumService extends Mock implements RemoteAlbumService {}

class _MockRemoteAlbum extends Mock implements RemoteAlbum {}

void main() {
  testWidgets('drops the old album subtree immediately when viewer scope changes', (tester) async {
    final service = _MockRemoteAlbumService();
    final albumA = _MockRemoteAlbum();
    final albumB = _MockRemoteAlbum();
    final albumsA = StreamController<RemoteAlbum?>();
    final albumsB = StreamController<RemoteAlbum?>();
    addTearDown(albumsA.close);
    addTearDown(albumsB.close);

    final viewer = StateProvider<RemoteViewerScope?>((_) => const RemoteViewerScope(viewerId: 'A', sessionEpoch: 1));
    when(() => service.watchAlbum('album', 'A')).thenAnswer((_) => albumsA.stream);
    when(() => service.watchAlbum('album', 'B')).thenAnswer((_) => albumsB.stream);

    await tester.pumpWidget(
      ProviderScope(
        overrides: [
          remoteAlbumServiceProvider.overrideWithValue(service),
          remoteViewerScopeProvider.overrideWith((ref) => ref.watch(viewer)),
        ],
        child: MaterialApp(
          home: RemoteAlbumScopeBoundary(
            albumId: 'album',
            loadingBuilder: (_) => const Text('loading'),
            unavailableBuilder: (_) => const Text('unavailable'),
            builder: (_, scope, album) => Text('${scope.viewerId}:${identical(album, albumA) ? 'A' : 'B'}'),
          ),
        ),
      ),
    );

    albumsA.add(albumA);
    await tester.pump();
    expect(find.text('A:A'), findsOneWidget);

    final container = ProviderScope.containerOf(tester.element(find.byType(RemoteAlbumScopeBoundary)));
    container.read(viewer.notifier).state = const RemoteViewerScope(viewerId: 'B', sessionEpoch: 2);
    await tester.pump();
    expect(find.text('A:A'), findsNothing);
    expect(find.text('loading'), findsOneWidget);

    albumsA.add(albumA);
    await tester.pump();
    expect(find.text('A:A'), findsNothing);

    albumsB.add(albumB);
    await tester.pumpAndSettle();
    expect(find.text('B:B'), findsOneWidget);
  });
}
