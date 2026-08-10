import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/models/albums/album_search.model.dart';
import 'package:immich_mobile/providers/album/album_sort_by_options.provider.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:logging/logging.dart';

class RemoteAlbumState {
  final List<RemoteAlbum> albums;

  const RemoteAlbumState({required this.albums});

  RemoteAlbumState copyWith({List<RemoteAlbum>? albums}) {
    return RemoteAlbumState(albums: albums ?? this.albums);
  }

  @override
  String toString() => 'RemoteAlbumState(albums: ${albums.length})';

  @override
  bool operator ==(covariant RemoteAlbumState other) {
    if (identical(this, other)) return true;
    final listEquals = const DeepCollectionEquality().equals;

    return listEquals(other.albums, albums);
  }

  @override
  int get hashCode => albums.hashCode;
}

class RemoteAlbumNotifier extends Notifier<RemoteAlbumState> {
  late RemoteAlbumService _remoteAlbumService;
  RemoteViewerScope? _viewerScope;
  final _logger = Logger('RemoteAlbumNotifier');

  @override
  RemoteAlbumState build() {
    _remoteAlbumService = ref.read(remoteAlbumServiceProvider);
    _viewerScope = ref.watch(remoteViewerScopeProvider);
    return const RemoteAlbumState(albums: []);
  }

  Future<List<RemoteAlbum>> _getAll() async {
    try {
      final scope = _viewerScope;
      if (scope == null) {
        state = const RemoteAlbumState(albums: []);
        return const [];
      }
      final albums = await _remoteAlbumService.getAll(scope.viewerId);
      if (_viewerScope != scope) {
        return albums;
      }
      state = state.copyWith(albums: albums);
      return albums;
    } catch (error, stack) {
      _logger.severe('Failed to fetch albums', error, stack);
      rethrow;
    }
  }

  Future<void> refresh() async {
    await _getAll();
  }

  List<RemoteAlbum> searchAlbums(
    List<RemoteAlbum> albums,
    String query,
    String? userId, [
    QuickFilterMode filterMode = QuickFilterMode.all,
  ]) {
    return _remoteAlbumService.searchAlbums(albums, query, userId, filterMode);
  }

  Future<List<RemoteAlbum>> sortAlbums(
    List<RemoteAlbum> albums,
    AlbumSortMode sortMode, {
    bool isReverse = false,
  }) async {
    return await _remoteAlbumService.sortAlbums(albums, sortMode, isReverse: isReverse);
  }

  Future<RemoteAlbum?> createAlbum({
    required String title,
    String? description,
    List<String> assetIds = const [],
  }) async {
    _requireRemoteMutation();
    try {
      final currentUser = ref.read(currentUserProvider);
      if (currentUser == null) {
        throw Exception('User not logged in');
      }

      final album = await _remoteAlbumService.createAlbum(
        title: title,
        owner: currentUser,
        description: description,
        assetIds: assetIds,
      );

      state = state.copyWith(albums: [...state.albums, album]);

      return album;
    } catch (error, stack) {
      _logger.severe('Failed to create album', error, stack);
      rethrow;
    }
  }

  Future<RemoteAlbum?> updateAlbum(
    String albumId, {
    String? name,
    String? description,
    String? thumbnailAssetId,
    bool? isActivityEnabled,
    AlbumAssetOrder? order,
  }) async {
    _requireRemoteMutation();
    try {
      final updatedAlbum = await _remoteAlbumService.updateAlbum(
        albumId,
        name: name,
        description: description,
        thumbnailAssetId: thumbnailAssetId,
        isActivityEnabled: isActivityEnabled,
        order: order,
      );

      final updatedAlbums = state.albums.map((album) {
        return album.id == albumId ? updatedAlbum : album;
      }).toList();

      state = state.copyWith(albums: updatedAlbums);

      return updatedAlbum;
    } catch (error, stack) {
      _logger.severe('Failed to update album', error, stack);
      rethrow;
    }
  }

  Future<RemoteAlbum?> toggleAlbumOrder(String albumId) async {
    final currentAlbum = state.albums.firstWhere((album) => album.id == albumId);

    final newOrder = currentAlbum.order == AlbumAssetOrder.asc ? AlbumAssetOrder.desc : AlbumAssetOrder.asc;

    return updateAlbum(albumId, order: newOrder);
  }

  Future<void> deleteAlbum(String albumId) async {
    _requireRemoteMutation();
    await _remoteAlbumService.deleteAlbum(albumId);

    final updatedAlbums = state.albums.where((album) => album.id != albumId).toList();
    state = state.copyWith(albums: updatedAlbums);
  }

  Future<List<RemoteAsset>> getAssets(String albumId) {
    final scope = ref.read(remoteAlbumScopeProvider(albumId));
    if (scope == null) {
      return Future.value(const []);
    }
    return _remoteAlbumService.getAssets(albumId, scope.viewerId);
  }

  Future<int> addAssets(String albumId, List<String> assetIds) {
    _requireRemoteMutation();
    return _remoteAlbumService.addAssets(albumId: albumId, assetIds: assetIds);
  }

  Future<void> addUsers(String albumId, List<String> userIds) {
    _requireRemoteMutation();
    return _remoteAlbumService.addUsers(albumId: albumId, userIds: userIds);
  }

  Future<void> removeUser(String albumId, String userId) {
    _requireRemoteMutation();
    return _remoteAlbumService.removeUser(albumId, userId: userId);
  }

  Future<void> leaveAlbum(String albumId, {required String userId}) async {
    _requireRemoteMutation();
    await _remoteAlbumService.removeUser(albumId, userId: userId);

    final updatedAlbums = state.albums.where((album) => album.id != albumId).toList();
    state = state.copyWith(albums: updatedAlbums);
  }

  Future<void> setActivityStatus(String albumId, bool enabled) {
    _requireRemoteMutation();
    return _remoteAlbumService.setActivityStatus(albumId, enabled);
  }

  void _requireRemoteMutation() {
    if (!ref.read(serverAccessProvider).allows(ServerCapability.remoteMutation)) {
      throw StateError('Server mutations require an online authenticated session');
    }
  }
}

final remoteViewerScopeProvider = Provider<RemoteViewerScope?>((ref) {
  final viewerId = ref.watch(currentUserProvider.select((user) => user?.id));
  if (viewerId == null) {
    return null;
  }
  final sessionEpoch = ref.watch(serverReachabilityStateProvider.select((state) => state.sessionEpoch));
  return RemoteViewerScope(viewerId: viewerId, sessionEpoch: sessionEpoch);
}, dependencies: [currentUserProvider, serverReachabilityStateProvider]);

final remoteAlbumScopeProvider = Provider.family<RemoteAlbumScope?, String>((ref, albumId) {
  final viewer = ref.watch(remoteViewerScopeProvider);
  return viewer == null ? null : RemoteAlbumScope(viewer: viewer, albumId: albumId);
}, dependencies: [remoteViewerScopeProvider]);

final remoteAlbumDateRangeProvider = FutureProvider.family<(DateTime, DateTime), RemoteAlbumScope>((ref, scope) async {
  final service = ref.watch(remoteAlbumServiceProvider);
  return service.getDateRange(scope.albumId, scope.viewerId);
});

final remoteAlbumSharedUsersProvider = FutureProvider.autoDispose.family<List<UserDto>, RemoteAlbumScope>((
  ref,
  scope,
) async {
  final link = ref.keepAlive();
  ref.onDispose(() => link.close());
  final service = ref.watch(remoteAlbumServiceProvider);
  return service.getSharedUsers(scope.albumId, scope.viewerId);
});
