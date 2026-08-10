import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/album/album.model.dart';
import 'package:immich_mobile/domain/models/album/remote_album_scope.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/memory.model.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/memory.service.dart';
import 'package:immich_mobile/domain/services/people.service.dart';
import 'package:immich_mobile/domain/services/remote_album.service.dart';
import 'package:immich_mobile/domain/services/timeline.service.dart';
import 'package:immich_mobile/services/deep_link.service.dart';
import 'package:mocktail/mocktail.dart';

class _MockTimelineFactory extends Mock implements TimelineFactory {}

class _MockAssetService extends Mock implements AssetService {}

class _MockRemoteAlbumService extends Mock implements RemoteAlbumService {}

class _MockMemoryService extends Mock implements DriftMemoryService {}

class _MockPeopleService extends Mock implements DriftPeopleService {}

class _MockWidgetRef extends Mock implements WidgetRef {}

class _MockRemoteAsset extends Mock implements RemoteAsset {}

class _MockRemoteAlbum extends Mock implements RemoteAlbum {}

class _MockMemory extends Mock implements DriftMemory {}

class _MockPerson extends Mock implements DriftPerson {}

void main() {
  late _MockTimelineFactory timelineFactory;
  late _MockAssetService assetService;
  late _MockRemoteAlbumService albumService;
  late _MockMemoryService memoryService;
  late _MockPeopleService peopleService;
  late RemoteViewerScope? scope;
  late DeepLinkService service;

  setUp(() {
    timelineFactory = _MockTimelineFactory();
    assetService = _MockAssetService();
    albumService = _MockRemoteAlbumService();
    memoryService = _MockMemoryService();
    peopleService = _MockPeopleService();
    scope = const RemoteViewerScope(viewerId: 'A', sessionEpoch: 1);
    service = DeepLinkService(timelineFactory, assetService, albumService, memoryService, peopleService, () => scope);
  });

  test('asset completion from viewer A does not navigate after switching to B', () async {
    final completion = Completer<RemoteAsset?>();
    final asset = _MockRemoteAsset();
    when(() => asset.ownerId).thenReturn('A');
    when(() => assetService.getRemoteAsset('asset')).thenAnswer((_) => completion.future);

    final route = service.buildAssetDeepLink('asset', _MockWidgetRef());
    scope = const RemoteViewerScope(viewerId: 'B', sessionEpoch: 2);
    completion.complete(asset);

    expect(await route, isNull);
    verifyNever(() => timelineFactory.fromAssets([asset], TimelineOrigin.deepLink));
  });

  test('asset deep link fails closed for an asset owned by another viewer', () async {
    final asset = _MockRemoteAsset();
    when(() => asset.ownerId).thenReturn('B');
    when(() => assetService.getRemoteAsset('asset')).thenAnswer((_) async => asset);

    expect(await service.buildAssetDeepLink('asset', _MockWidgetRef()), isNull);
    verifyNever(() => timelineFactory.fromAssets([asset], TimelineOrigin.deepLink));
  });

  test('album and activity completions are discarded after the viewer scope changes', () async {
    final albumCompletion = Completer<RemoteAlbum?>();
    final activityCompletion = Completer<RemoteAlbum?>();
    final album = _MockRemoteAlbum();
    when(() => album.isActivityEnabled).thenReturn(true);
    when(() => albumService.get('album', 'A')).thenAnswer((_) => albumCompletion.future);
    when(() => albumService.get('activity', 'A')).thenAnswer((_) => activityCompletion.future);

    final albumRoute = service.buildAlbumDeepLink('album');
    final activityRoute = service.buildActivityDeepLink('activity');
    scope = const RemoteViewerScope(viewerId: 'B', sessionEpoch: 2);
    albumCompletion.complete(album);
    activityCompletion.complete(album);

    expect(await albumRoute, isNull);
    expect(await activityRoute, isNull);
  });

  test('memory and people deep links fail closed when cached content belongs to another viewer', () async {
    final memory = _MockMemory();
    final person = _MockPerson();
    when(() => memory.ownerId).thenReturn('B');
    when(() => person.ownerId).thenReturn('B');
    when(() => memoryService.get('memory')).thenAnswer((_) async => memory);
    when(() => peopleService.get('person', 'A')).thenAnswer((_) async => person);

    expect(await service.buildMemoryDeepLink('memory'), isNull);
    expect(await service.buildPeopleDeepLink('person'), isNull);
  });
}
