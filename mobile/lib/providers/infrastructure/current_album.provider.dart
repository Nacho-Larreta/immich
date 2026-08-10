import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';

final currentRemoteAlbumScopedProvider = Provider<RemoteAlbumScope?>((ref) => null);

final remoteAlbumByScopeProvider = StreamProvider.autoDispose.family<RemoteAlbum?, RemoteAlbumScope>((ref, scope) {
  return ref.watch(remoteAlbumServiceProvider).watchAlbum(scope.albumId, scope.viewerId);
});

final currentRemoteAlbumProvider = Provider<RemoteAlbum?>((ref) {
  final scope = ref.watch(currentRemoteAlbumScopedProvider);
  if (scope == null) {
    return null;
  }
  return ref.watch(remoteAlbumByScopeProvider(scope)).valueOrNull;
}, dependencies: [currentRemoteAlbumScopedProvider]);
