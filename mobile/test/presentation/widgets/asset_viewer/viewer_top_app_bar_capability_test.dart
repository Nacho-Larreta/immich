import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/models/setting.model.dart';
import 'package:immich_mobile/domain/models/user.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/remote_mutation_guard.dart';
import 'package:immich_mobile/domain/services/setting.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/domain/services/user.service.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/asset_viewer/viewer_top_app_bar.widget.dart';
import 'package:immich_mobile/providers/activity_service.provider.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/cast.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/current_album.provider.dart';
import 'package:immich_mobile/providers/infrastructure/readonly_mode.provider.dart';
import 'package:immich_mobile/providers/infrastructure/setting.provider.dart';
import 'package:immich_mobile/providers/infrastructure/timeline.provider.dart';
import 'package:immich_mobile/providers/infrastructure/user.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/providers/server_info.provider.dart';
import 'package:immich_mobile/repositories/activity_api.repository.dart';
import 'package:immich_mobile/services/activity.service.dart';
import 'package:immich_mobile/services/gcast.service.dart';
import 'package:immich_mobile/services/server_info.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockActivityApiRepository extends Mock implements ActivityApiRepository {}

class _MockAssetService extends Mock implements AssetService {}

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _MockTimelineService extends Mock implements TimelineService {}

class _MockUserService extends Mock implements UserService {}

class _MockGCastService extends Mock implements GCastService {}

class _MockServerInfoService extends Mock implements ServerInfoService {}

class _MockSettingsService extends Mock implements SettingsService {}

class _TestReadonlyModeNotifier extends ReadOnlyModeNotifier {
  @override
  bool build() => false;
}

class _TestSettingsNotifier extends SettingsNotifier {
  _TestSettingsNotifier(this._settings);

  final SettingsService _settings;

  @override
  SettingsService build() => _settings;

  @override
  T get<T>(Setting<T> setting) => setting.defaultValue;
}

Future<void> main() async {
  final binding = TestWidgetsFlutterBinding.ensureInitialized();
  binding.defaultBinaryMessenger.setMockMethodCallHandler(
    const MethodChannel('plugins.flutter.io/shared_preferences'),
    (call) async => call.method == 'getAll' ? <String, Object>{} : null,
  );
  await EasyLocalization.ensureInitialized();
  final epoch = DateTime.fromMillisecondsSinceEpoch(0);
  final user = UserDto(id: 'viewer', email: 'viewer@example.com', name: 'Viewer', profileChangedAt: epoch);
  final album = RemoteAlbum(
    id: 'album',
    name: 'Shared album',
    ownerId: 'viewer',
    description: '',
    createdAt: epoch,
    updatedAt: epoch,
    isActivityEnabled: true,
    order: AlbumAssetOrder.desc,
    assetCount: 1,
    ownerName: 'Viewer',
    isShared: true,
  );
  const albumScope = RemoteAlbumScope(
    viewer: RemoteViewerScope(viewerId: 'viewer', sessionEpoch: 4),
    albumId: 'album',
  );

  for (final accessEntry in <String, ServerAccessPolicy>{
    'offline': const ServerAccessPolicy.offline(),
    'reauthentication': const ServerAccessPolicy.reauthenticationRequired(),
  }.entries) {
    for (final isFavorite in [false, true]) {
      testWidgets(
        '${accessEntry.key} album viewer does not read activities or expose remote actions when favorite=$isFavorite',
        (tester) async {
          final asset = _asset(isFavorite: isFavorite);
          final activityRepository = _MockActivityApiRepository();
          final assetService = _MockAssetService();
          final userService = _MockUserService();
          final timeline = _MockTimelineService();
          final access = accessEntry.value;

          when(() => assetService.watchAsset(asset)).thenAnswer((_) => Stream.value(asset));
          when(() => userService.tryGetMyUser()).thenReturn(user);
          when(() => userService.watchMyUser()).thenAnswer((_) => const Stream<UserDto?>.empty());
          when(() => timeline.origin).thenReturn(TimelineOrigin.albumActivities);

          final container = ProviderContainer(
            overrides: [
              serverAccessProvider.overrideWithValue(access),
              currentRemoteAlbumProvider.overrideWithValue(album),
              currentRemoteAlbumScopedProvider.overrideWithValue(albumScope),
              assetServiceProvider.overrideWithValue(assetService),
              userServiceProvider.overrideWithValue(userService),
              timelineServiceProvider.overrideWithValue(timeline),
              readonlyModeProvider.overrideWith(_TestReadonlyModeNotifier.new),
              settingsProvider.overrideWith(() => _TestSettingsNotifier(_MockSettingsService())),
              castProvider.overrideWith((_) => CastNotifier(_MockGCastService())),
              serverInfoProvider.overrideWith((_) => ServerInfoNotifier(_MockServerInfoService())),
              activityServiceProvider.overrideWithValue(
                ActivityService(
                  activityRepository,
                  _MockTimelineFactory(),
                  assetService,
                  RemoteMutationGuard(() => access),
                ),
              ),
            ],
          );
          addTearDown(container.dispose);
          container.read(assetViewerProvider.notifier).setAsset(asset);

          await tester.pumpWidget(_harness(container));
          await tester.pump();

          expect(find.byIcon(Icons.more_vert_rounded), findsOneWidget);
          expect(find.byIcon(Icons.chat_outlined), findsNothing);
          expect(find.byIcon(Icons.favorite_border_rounded), findsNothing);
          expect(find.byIcon(Icons.favorite_rounded), findsNothing);
          verifyNever(() => activityRepository.getAll('album', assetId: 'asset'));
        },
      );
    }
  }
}

Widget _harness(ProviderContainer container) => UncontrolledProviderScope(
  container: container,
  child: EasyLocalization(
    supportedLocales: const [Locale('en')],
    path: 'unused',
    fallbackLocale: const Locale('en'),
    saveLocale: false,
    assetLoader: const CodegenLoader(),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        home: const Scaffold(appBar: ViewerTopAppBar()),
      ),
    ),
  ),
);

RemoteAsset _asset({required bool isFavorite}) => RemoteAsset(
  id: 'asset',
  name: 'asset.jpg',
  ownerId: 'viewer',
  checksum: 'checksum',
  type: AssetType.image,
  createdAt: DateTime.fromMillisecondsSinceEpoch(0),
  updatedAt: DateTime.fromMillisecondsSinceEpoch(0),
  isFavorite: isFavorite,
  isEdited: false,
);
