import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';

typedef ResolvedRemoteAlbumBuilder = Widget Function(BuildContext context, RemoteAlbumScope scope, RemoteAlbum album);

class RemoteAlbumScopeBoundary extends ConsumerWidget {
  const RemoteAlbumScopeBoundary({
    super.key,
    required this.albumId,
    required this.builder,
    required this.loadingBuilder,
    required this.unavailableBuilder,
  });

  final String albumId;
  final ResolvedRemoteAlbumBuilder builder;
  final WidgetBuilder loadingBuilder;
  final WidgetBuilder unavailableBuilder;

  @override
  Widget build(BuildContext context, WidgetRef ref) {
    final scope = ref.watch(remoteAlbumScopeProvider(albumId));
    if (scope == null) {
      return unavailableBuilder(context);
    }

    final albumState = ref.watch(remoteAlbumByScopeProvider(scope));
    return albumState.when(
      data: (album) {
        if (album == null) {
          return unavailableBuilder(context);
        }
        return ProviderScope(
          key: ValueKey(scope),
          overrides: [currentRemoteAlbumScopedProvider.overrideWithValue(scope)],
          child: builder(context, scope, album),
        );
      },
      error: (_, _) => unavailableBuilder(context),
      loading: () => loadingBuilder(context),
    );
  }
}
