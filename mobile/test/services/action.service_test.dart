import 'package:drift/drift.dart' as drift;
import 'package:drift/native.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/services/remote_mutation_guard.dart';
import 'package:immich_mobile/domain/services/store.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/store.repository.dart';
import 'package:immich_mobile/repositories/download.repository.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:mocktail/mocktail.dart';

import '../infrastructure/repository.mock.dart';
import '../repository.mocks.dart';

class MockDownloadRepository extends Mock implements DownloadRepository {}

void main() {
  late ActionService sut;

  late MockAssetApiRepository assetApiRepository;
  late MockRemoteAssetRepository remoteAssetRepository;
  late MockDriftLocalAssetRepository localAssetRepository;
  late MockDriftAlbumApiRepository albumApiRepository;
  late MockRemoteAlbumRepository remoteAlbumRepository;
  late MockTrashedLocalAssetRepository trashedLocalAssetRepository;
  late MockAssetMediaRepository assetMediaRepository;
  late MockDownloadRepository downloadRepository;
  late ServerAccessPolicy accessPolicy;

  late Drift db;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    debugDefaultTargetPlatformOverride = TargetPlatform.android;

    db = Drift(drift.DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    await StoreService.init(storeRepository: DriftStoreRepository(db));
  });

  tearDownAll(() async {
    debugDefaultTargetPlatformOverride = null;
    await Store.clear();
    await db.close();
  });

  setUp(() {
    assetApiRepository = MockAssetApiRepository();
    remoteAssetRepository = MockRemoteAssetRepository();
    localAssetRepository = MockDriftLocalAssetRepository();
    albumApiRepository = MockDriftAlbumApiRepository();
    remoteAlbumRepository = MockRemoteAlbumRepository();
    trashedLocalAssetRepository = MockTrashedLocalAssetRepository();
    assetMediaRepository = MockAssetMediaRepository();
    downloadRepository = MockDownloadRepository();
    accessPolicy = const ServerAccessPolicy.online();

    sut = ActionService(
      assetApiRepository,
      remoteAssetRepository,
      localAssetRepository,
      albumApiRepository,
      remoteAlbumRepository,
      trashedLocalAssetRepository,
      assetMediaRepository,
      downloadRepository,
      RemoteMutationGuard(() => accessPolicy),
    );
  });

  tearDown(() async {
    await Store.clear();
  });

  group('ActionService.deleteLocal', () {
    test('routes deleted ids to trashed repository when Android trash handling is enabled', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      const ids = ['a', 'b'];

      when(() => assetMediaRepository.deleteAll(ids)).thenAnswer((_) async => ids);
      when(() => trashedLocalAssetRepository.applyTrashedAssets(ids)).thenAnswer((_) async {});

      final result = await sut.deleteLocal(ids);

      expect(result, ids.length);
      verify(() => assetMediaRepository.deleteAll(ids)).called(1);
      verify(() => trashedLocalAssetRepository.applyTrashedAssets(ids)).called(1);
      verifyNever(() => localAssetRepository.delete(any()));
    });

    test('deletes locally when Android trash handling is disabled', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, false);
      const ids = ['c'];

      when(() => assetMediaRepository.deleteAll(ids)).thenAnswer((_) async => ids);
      when(() => localAssetRepository.delete(ids)).thenAnswer((_) async {});

      final result = await sut.deleteLocal(ids);

      expect(result, ids.length);
      verify(() => assetMediaRepository.deleteAll(ids)).called(1);
      verify(() => localAssetRepository.delete(ids)).called(1);
      verifyNever(() => trashedLocalAssetRepository.applyTrashedAssets(any()));
    });

    test('short-circuits when nothing was deleted', () async {
      await Store.put(StoreKey.manageLocalMediaAndroid, true);
      const ids = ['x'];

      when(() => assetMediaRepository.deleteAll(ids)).thenAnswer((_) async => <String>[]);

      final result = await sut.deleteLocal(ids);

      expect(result, 0);
      verify(() => assetMediaRepository.deleteAll(ids)).called(1);
      verifyNever(() => trashedLocalAssetRepository.applyTrashedAssets(any()));
      verifyNever(() => localAssetRepository.delete(any()));
    });
  });

  group('ActionService.unStack', () {
    const stackIds = ['stack-a', 'stack-b'];

    test('does not mutate local state when the API request fails', () async {
      when(() => assetApiRepository.unStack(stackIds)).thenAnswer((_) async => throw StateError('offline'));
      when(() => remoteAssetRepository.unStack(stackIds)).thenAnswer((_) async {});

      await expectLater(sut.unStack(stackIds), throwsA(isA<StateError>()));

      verify(() => assetApiRepository.unStack(stackIds)).called(1);
      verifyNever(() => remoteAssetRepository.unStack(any()));
    });

    test('updates the API before mutating local state', () async {
      final calls = <String>[];
      when(() => assetApiRepository.unStack(stackIds)).thenAnswer((_) async => calls.add('api'));
      when(() => remoteAssetRepository.unStack(stackIds)).thenAnswer((_) async => calls.add('local'));

      await sut.unStack(stackIds);

      expect(calls, ['api', 'local']);
      verify(() => assetApiRepository.unStack(stackIds)).called(1);
      verify(() => remoteAssetRepository.unStack(stackIds)).called(1);
    });
  });

  group('remote mutation boundary', () {
    for (final entry in <String, ServerAccessPolicy>{
      'offline': const ServerAccessPolicy.offline(),
      'reauthentication': const ServerAccessPolicy.reauthenticationRequired(),
    }.entries) {
      test('blocks asset mutation families before API calls while ${entry.key}', () async {
        accessPolicy = entry.value;

        await expectLater(sut.favorite(const ['asset']), throwsA(isA<StateError>()));
        await expectLater(sut.archive(const ['asset']), throwsA(isA<StateError>()));
        await expectLater(sut.trash(const ['asset']), throwsA(isA<StateError>()));
        await expectLater(sut.stack('viewer', const ['asset']), throwsA(isA<StateError>()));

        verifyNever(() => assetApiRepository.updateFavorite(const ['asset'], true));
        verifyNever(() => assetApiRepository.updateVisibility(const ['asset'], AssetVisibilityEnum.archive));
        verifyNever(() => assetApiRepository.delete(const ['asset'], false));
        verifyNever(() => assetApiRepository.stack(const ['asset']));
        verifyNever(() => remoteAssetRepository.updateFavorite(const ['asset'], true));
        verifyNever(() => remoteAssetRepository.updateVisibility(const ['asset'], AssetVisibility.archive));
        verifyNever(() => remoteAssetRepository.trash(const ['asset']));
      });
    }

    test('preserves local deletion for a local-only mixed action while offline', () async {
      accessPolicy = const ServerAccessPolicy.offline();
      const localIds = ['local'];
      when(() => assetMediaRepository.deleteAll(localIds)).thenAnswer((_) async => localIds);
      when(() => localAssetRepository.delete(localIds)).thenAnswer((_) async {});

      await sut.trashRemoteAndDeleteLocal(const [], localIds);

      verifyNever(() => assetApiRepository.delete(any(), any()));
      verifyNever(() => remoteAssetRepository.trash(any()));
      verify(() => assetMediaRepository.deleteAll(localIds)).called(1);
      verify(() => localAssetRepository.delete(localIds)).called(1);
    });
  });
}
