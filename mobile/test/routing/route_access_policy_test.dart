import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/routing/auth_guard.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/api.service.dart';
import 'package:immich_mobile/services/local_auth.service.dart';
import 'package:immich_mobile/services/secure_storage.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockApiService extends Mock implements ApiService {}

class _MockGalleryPermissionNotifier extends Mock implements GalleryPermissionNotifier {}

class _MockSecureStorageService extends Mock implements SecureStorageService {}

class _MockLocalAuthService extends Mock implements LocalAuthService {}

void main() {
  test('explicit logout returns to the local-first timeline shell', () {
    final destination = localShellAfterLogout();

    expect(destination, isA<TabShellRoute>());
    expect(destination.initialChildren, hasLength(1));
    expect(destination.initialChildren!.single, isA<MainTimelineRoute>());
  });

  test('local shell, timeline, local albums, and asset viewer do not require remote authentication', () {
    final router = AppRouter(
      _MockApiService(),
      () async {},
      _MockGalleryPermissionNotifier(),
      _MockSecureStorageService(),
      _MockLocalAuthService(),
    );

    for (final routeName in [
      TabShellRoute.name,
      MainTimelineRoute.name,
      LocalTimelineRoute.name,
      DriftLocalAlbumsRoute.name,
      AssetViewerRoute.name,
    ]) {
      final route = router.routes.firstWhere((candidate) => candidate.name == routeName);
      expect(route.guards.whereType<AuthGuard>(), isEmpty, reason: '$routeName must stay available offline');
    }
  });

  test('remote-only routes keep an authentication capability gate', () {
    final router = AppRouter(
      _MockApiService(),
      () async {},
      _MockGalleryPermissionNotifier(),
      _MockSecureStorageService(),
      _MockLocalAuthService(),
    );

    for (final routeName in [SharedLinkRoute.name, RemoteAlbumRoute.name, DriftPartnerRoute.name]) {
      final route = router.routes.firstWhere((candidate) => candidate.name == routeName);
      expect(route.guards.whereType<AuthGuard>(), hasLength(1), reason: '$routeName needs remote authentication');
    }
  });
}
