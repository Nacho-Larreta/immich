import 'package:auto_route/auto_route.dart';
import 'package:flutter/foundation.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart' as beta_asset_service;
import 'package:immich_mobile/domain/services/memory.service.dart';
import 'package:immich_mobile/domain/services/people.service.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/asset_viewer.page.dart';
import 'package:immich_mobile/providers/infrastructure/album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart' as beta_asset_provider;
import 'package:immich_mobile/providers/infrastructure/memory.provider.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';
import 'package:immich_mobile/providers/infrastructure/remote_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/routing/router.dart';

final deepLinkServiceProvider = Provider(
  (ref) => DeepLinkService(
    ref.watch(timelineFactoryProvider),
    ref.watch(beta_asset_provider.assetServiceProvider),
    ref.watch(remoteAlbumServiceProvider),
    ref.watch(driftMemoryServiceProvider),
    ref.watch(driftPeopleServiceProvider),
    () => ref.read(remoteViewerScopeProvider),
  ),
);

class DeepLinkService {
  final TimelineFactory _betaTimelineFactory;
  final beta_asset_service.AssetService _betaAssetService;
  final RemoteAlbumService _betaRemoteAlbumService;
  final DriftMemoryService _betaMemoryService;
  final DriftPeopleService _betaPeopleService;

  final RemoteViewerScope? Function() _readRemoteViewerScope;

  const DeepLinkService(
    this._betaTimelineFactory,
    this._betaAssetService,
    this._betaRemoteAlbumService,
    this._betaMemoryService,
    this._betaPeopleService,
    this._readRemoteViewerScope,
  );

  DeepLink _handleColdStart(PageRouteInfo<dynamic> route, bool isColdStart) {
    return DeepLink([
      // we need something to segue back to if the app was cold started
      // TODO: use MainTimelineRoute this when beta is default
      if (isColdStart) const TabShellRoute(),
      route,
    ]);
  }

  Future<DeepLink> handleScheme(PlatformDeepLink link, WidgetRef ref, bool isColdStart) async {
    // get everything after the scheme, since Uri cannot parse path
    final intent = link.uri.host;
    final queryParams = link.uri.queryParameters;

    PageRouteInfo<dynamic>? deepLinkRoute = switch (intent) {
      "memory" => await buildMemoryDeepLink(queryParams['id'] ?? ''),
      "asset" => await buildAssetDeepLink(queryParams['id'] ?? '', ref),
      "album" => await buildAlbumDeepLink(queryParams['id'] ?? ''),
      "people" => await buildPeopleDeepLink(queryParams['id'] ?? ''),
      "activity" => await buildActivityDeepLink(queryParams['albumId'] ?? ''),
      _ => null,
    };

    // Deep link resolution failed, safely handle it based on the app state
    if (deepLinkRoute == null) {
      if (isColdStart) {
        return DeepLink.defaultPath;
      }

      return DeepLink.none;
    }

    return _handleColdStart(deepLinkRoute, isColdStart);
  }

  Future<DeepLink> handleMyImmichApp(PlatformDeepLink link, WidgetRef ref, bool isColdStart) async {
    final path = link.uri.path;

    const uuidRegex = r'[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}';
    final assetRegex = RegExp('/photos/($uuidRegex)');
    final albumRegex = RegExp('/albums/($uuidRegex)');
    final peopleRegex = RegExp('/people/($uuidRegex)');

    PageRouteInfo<dynamic>? deepLinkRoute;
    if (assetRegex.hasMatch(path)) {
      final assetId = assetRegex.firstMatch(path)?.group(1) ?? '';
      deepLinkRoute = await buildAssetDeepLink(assetId, ref);
    } else if (albumRegex.hasMatch(path)) {
      final albumId = albumRegex.firstMatch(path)?.group(1) ?? '';
      deepLinkRoute = await buildAlbumDeepLink(albumId);
    } else if (peopleRegex.hasMatch(path)) {
      final peopleId = peopleRegex.firstMatch(path)?.group(1) ?? '';
      deepLinkRoute = await buildPeopleDeepLink(peopleId);
    } else if (path == "/memory") {
      deepLinkRoute = await buildMemoryDeepLink(null);
    }

    // Deep link resolution failed, safely handle it based on the app state
    if (deepLinkRoute == null) {
      if (isColdStart) return DeepLink.defaultPath;
      return DeepLink.none;
    }

    return _handleColdStart(deepLinkRoute, isColdStart);
  }

  @visibleForTesting
  Future<PageRouteInfo?> buildMemoryDeepLink(String? memoryId) async {
    final initialScope = _readRemoteViewerScope();
    if (initialScope == null) {
      return null;
    }

    List<DriftMemory> memories = [];

    if (memoryId == null) {
      memories = (await _betaMemoryService.getMemoryLane(
        initialScope.viewerId,
      )).where((memory) => memory.ownerId == initialScope.viewerId).toList(growable: false);
    } else {
      final memory = await _betaMemoryService.get(memoryId);
      if (memory != null && memory.ownerId == initialScope.viewerId) {
        memories = [memory];
      }
    }

    if (_readRemoteViewerScope() != initialScope || memories.isEmpty) {
      return null;
    }

    return DriftMemoryRoute(memories: memories, memoryIndex: 0);
  }

  @visibleForTesting
  Future<PageRouteInfo?> buildAssetDeepLink(String assetId, WidgetRef ref) async {
    final initialScope = _readRemoteViewerScope();
    if (initialScope == null) {
      return null;
    }

    final asset = await _betaAssetService.getRemoteAsset(assetId);
    if (asset == null || asset.ownerId != initialScope.viewerId || _readRemoteViewerScope() != initialScope) {
      return null;
    }

    AssetViewer.setAsset(ref, asset);
    return AssetViewerRoute(
      initialIndex: 0,
      timelineService: _betaTimelineFactory.fromAssets([asset], TimelineOrigin.deepLink),
    );
  }

  @visibleForTesting
  Future<PageRouteInfo?> buildAlbumDeepLink(String albumId) async {
    final initialScope = _readRemoteViewerScope();
    if (initialScope == null) {
      return null;
    }
    final album = await _betaRemoteAlbumService.get(albumId, initialScope.viewerId);

    if (album == null || _readRemoteViewerScope() != initialScope) {
      return null;
    }

    return RemoteAlbumRoute(album: album);
  }

  @visibleForTesting
  Future<PageRouteInfo?> buildActivityDeepLink(String albumId) async {
    final initialScope = _readRemoteViewerScope();
    if (initialScope == null) {
      return null;
    }
    final album = await _betaRemoteAlbumService.get(albumId, initialScope.viewerId);

    if (album == null || album.isActivityEnabled == false || _readRemoteViewerScope() != initialScope) {
      return null;
    }

    return DriftActivitiesRoute(album: album);
  }

  @visibleForTesting
  Future<PageRouteInfo?> buildPeopleDeepLink(String personId) async {
    final initialScope = _readRemoteViewerScope();
    if (initialScope == null) {
      return null;
    }
    final person = await _betaPeopleService.get(personId, initialScope.viewerId);

    if (person == null || person.ownerId != initialScope.viewerId || _readRemoteViewerScope() != initialScope) {
      return null;
    }

    return DriftPersonRoute(person: person);
  }
}
