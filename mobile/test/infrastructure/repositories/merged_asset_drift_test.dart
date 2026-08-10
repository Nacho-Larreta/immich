import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline_source_filter.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/entities/local_album.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_album_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/local_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/stack.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/user.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  late Drift db;

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
  });

  tearDown(() async {
    await db.close();
  });

  test('mergedBucket falls back to createdAt when localDateTime is null', () async {
    const userId = 'user-1';
    final createdAt = DateTime(2024, 1, 1, 12);

    await db
        .into(db.userEntity)
        .insert(UserEntityCompanion.insert(id: userId, email: 'user-1@test.dev', name: 'User 1'));

    await db
        .into(db.remoteAssetEntity)
        .insert(
          RemoteAssetEntityCompanion.insert(
            id: 'asset-1',
            name: 'asset-1.jpg',
            type: AssetType.image,
            checksum: 'checksum-1',
            ownerId: userId,
            visibility: AssetVisibility.timeline,
            createdAt: Value(createdAt),
            updatedAt: Value(createdAt),
            localDateTime: const Value(null),
          ),
        );

    final buckets = await db.mergedAssetDrift
        .mergedBucket(
          groupBy: GroupAssetsBy.day.index,
          sourceFilter: TimelineSourceFilter.combined.index,
          userIds: [userId],
        )
        .get();

    expect(buckets, hasLength(1));
    expect(buckets.single.assetCount, 1);
    expect(buckets.single.bucketDate, isNotEmpty);
  });

  test('main timeline filters every authorized local asset without depending on backup selection', () async {
    const userId = 'user-1';
    final createdAt = DateTime(2024, 1, 1, 12);
    await _insertUser(db, userId);
    await _insertAlbum(db, 'selected', BackupSelection.selected);
    await _insertAlbum(db, 'none', BackupSelection.none);
    await _insertAlbum(db, 'excluded', BackupSelection.excluded);

    await _insertLocal(db, 'local-selected', 'selected-checksum', createdAt);
    await _insertLocal(db, 'local-none', 'none-checksum', createdAt.add(const Duration(minutes: 1)));
    await _insertLocal(db, 'local-excluded', 'excluded-checksum', createdAt.add(const Duration(minutes: 2)));
    await _insertLocal(db, 'local-unassigned', 'unassigned-checksum', createdAt.add(const Duration(minutes: 3)));
    await _addToAlbum(db, 'local-selected', 'selected');
    await _addToAlbum(db, 'local-none', 'none');
    await _addToAlbum(db, 'local-excluded', 'excluded');

    final repository = DriftTimelineRepository(db);
    final query = repository.main([userId], GroupAssetsBy.day, TimelineSourceFilter.device);
    final assets = await query.assetSource(0, 20);
    final buckets = await query.bucketSource().first;

    expect(assets.map((asset) => asset.localId), {
      'local-selected',
      'local-none',
      'local-excluded',
      'local-unassigned',
    });
    expect(assets, everyElement(predicate<BaseAsset>((asset) => asset.hasLocal)));
    expect(buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount), assets.length);
  });

  test('device timeline works without any server user ids', () async {
    final createdAt = DateTime(2024, 1, 3, 12);
    await _insertLocal(db, 'phone-only', 'phone-only-checksum', createdAt);

    final query = DriftTimelineRepository(db).main(const [], GroupAssetsBy.day, TimelineSourceFilter.device);
    final assets = await query.assetSource(0, 20);
    final buckets = await query.bucketSource().first;

    expect(assets.map((asset) => asset.localId), ['phone-only']);
    expect(buckets, hasLength(1));
    expect(buckets.single.assetCount, 1);
  });

  test('device combined and server share reconciliation, pagination, and bucket predicates', () async {
    const userId = 'user-1';
    const partnerId = 'partner-1';
    final createdAt = DateTime(2024, 2, 1, 12);
    await _insertUser(db, userId);
    await _insertUser(db, partnerId);

    await _insertLocal(db, 'local-only', 'local-only-checksum', createdAt);
    await _insertLocal(db, 'merged-local', 'merged-checksum', createdAt.add(const Duration(minutes: 1)));
    await _insertRemote(db, 'merged-remote', 'merged-checksum', userId, createdAt.add(const Duration(minutes: 1)));
    await _insertRemote(db, 'remote-only', 'remote-only-checksum', userId, createdAt.add(const Duration(minutes: 2)));
    await _insertRemote(db, 'partner-remote', 'partner-checksum', partnerId, createdAt.add(const Duration(minutes: 3)));
    await _insertRemote(
      db,
      'hidden-remote',
      'hidden-checksum',
      userId,
      createdAt.add(const Duration(minutes: 4)),
      visibility: AssetVisibility.hidden,
    );
    await _insertRemote(
      db,
      'deleted-remote',
      'deleted-checksum',
      userId,
      createdAt.add(const Duration(minutes: 5)),
      deletedAt: createdAt,
    );

    final repository = DriftTimelineRepository(db);
    final expected = <TimelineSourceFilter, Set<String>>{
      TimelineSourceFilter.device: {'local-only', 'merged-local'},
      TimelineSourceFilter.combined: {'local-only', 'merged-remote', 'remote-only', 'partner-remote'},
      TimelineSourceFilter.server: {'merged-remote', 'remote-only', 'partner-remote'},
    };

    for (final entry in expected.entries) {
      final query = repository.main([userId, partnerId], GroupAssetsBy.day, entry.key);
      final assets = await query.assetSource(0, 20);
      final buckets = await query.bucketSource().first;
      final page = await query.assetSource(1, 2);

      expect(
        assets.map(
          (asset) => entry.key == TimelineSourceFilter.device ? asset.localId! : asset.remoteId ?? asset.localId!,
        ),
        entry.value,
        reason: entry.key.name,
      );
      final identities = assets.map(_assetIdentity).toList();
      expect(identities.toSet(), hasLength(identities.length), reason: '${entry.key.name} exact uniqueness');
      expect(buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount), assets.length);
      expect(page, orderedEquals(assets.skip(1).take(2)), reason: '${entry.key.name} pagination');
      expect(await query.assetSource(assets.length, 1), isEmpty, reason: '${entry.key.name} end boundary');
      expect(await query.assetSource(0, 0), isEmpty, reason: '${entry.key.name} zero page size');
    }

    final combined = repository.main([userId, partnerId], GroupAssetsBy.day, TimelineSourceFilter.combined);
    final mergedAssets = (await combined.assetSource(0, 20)).where((asset) => asset.checksum == 'merged-checksum');
    expect(mergedAssets, hasLength(1));
    expect(mergedAssets.single.storage, AssetState.merged);
  });

  test('bucket queries preserve multiple days for every source', () async {
    const userId = 'user-1';
    final firstDay = DateTime(2024, 3, 1, 12);
    final secondDay = DateTime(2024, 3, 2, 12);
    await _insertUser(db, userId);
    await _insertLocal(db, 'local-day-1', 'local-day-1-checksum', firstDay);
    await _insertLocal(db, 'local-day-2', 'local-day-2-checksum', secondDay);
    await _insertRemote(db, 'remote-day-1', 'remote-day-1-checksum', userId, firstDay);
    await _insertRemote(db, 'remote-day-2', 'remote-day-2-checksum', userId, secondDay);

    final repository = DriftTimelineRepository(db);
    final expectedCounts = <TimelineSourceFilter, List<int>>{
      TimelineSourceFilter.device: [1, 1],
      TimelineSourceFilter.combined: [2, 2],
      TimelineSourceFilter.server: [1, 1],
    };

    for (final entry in expectedCounts.entries) {
      final buckets = await repository.main([userId], GroupAssetsBy.day, entry.key).bucketSource().first;
      expect(buckets, everyElement(isA<TimeBucket>()), reason: entry.key.name);
      expect(buckets.map((bucket) => bucket.assetCount), entry.value, reason: '${entry.key.name} day counts');
      final dates = buckets.cast<TimeBucket>().map((bucket) => bucket.date).toSet();
      expect(dates, hasLength(2), reason: '${entry.key.name} distinct days');
    }
  });

  test('server and combined timelines expose only the primary asset of a stack', () async {
    const userId = 'user-1';
    final createdAt = DateTime(2024, 4, 1, 12);
    await _insertUser(db, userId);
    await _insertRemote(db, 'stack-primary', 'primary-checksum', userId, createdAt, stackId: 'stack-1');
    await _insertRemote(
      db,
      'stack-secondary',
      'secondary-checksum',
      userId,
      createdAt.add(const Duration(minutes: 1)),
      stackId: 'stack-1',
    );
    await db
        .into(db.stackEntity)
        .insert(StackEntityCompanion.insert(id: 'stack-1', ownerId: userId, primaryAssetId: 'stack-primary'));

    final repository = DriftTimelineRepository(db);
    for (final source in [TimelineSourceFilter.combined, TimelineSourceFilter.server]) {
      final query = repository.main([userId], GroupAssetsBy.day, source);
      final assets = await query.assetSource(0, 20);
      final buckets = await query.bucketSource().first;

      expect(assets.map((asset) => asset.remoteId), ['stack-primary'], reason: source.name);
      expect(buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount), 1, reason: source.name);
    }
  });

  test('same checksum from different server users remains unique by remote identity', () async {
    const userId = 'user-1';
    const partnerId = 'partner-1';
    final createdAt = DateTime(2024, 5, 1, 12);
    await _insertUser(db, userId);
    await _insertUser(db, partnerId);
    await _insertLocal(db, 'same-local', 'same-checksum', createdAt);
    await _insertRemote(db, 'same-user', 'same-checksum', userId, createdAt);
    await _insertRemote(db, 'same-partner', 'same-checksum', partnerId, createdAt);

    final repository = DriftTimelineRepository(db);
    for (final source in [TimelineSourceFilter.combined, TimelineSourceFilter.server]) {
      final assets = await repository.main([userId, partnerId], GroupAssetsBy.day, source).assetSource(0, 20);
      final identities = assets.map(_assetIdentity).toList();

      expect(identities, containsAll(<String>['remote:same-user', 'remote:same-partner']), reason: source.name);
      expect(identities, hasLength(2), reason: source.name);
      expect(identities.toSet(), hasLength(2), reason: '${source.name} exact uniqueness');
    }
  });
}

String _assetIdentity(BaseAsset asset) =>
    asset.remoteId != null ? 'remote:${asset.remoteId}' : 'local:${asset.localId}';

Future<void> _insertUser(Drift db, String id) =>
    db.into(db.userEntity).insert(UserEntityCompanion.insert(id: id, email: '$id@test.dev', name: id));

Future<void> _insertAlbum(Drift db, String id, BackupSelection selection) =>
    db.into(db.localAlbumEntity).insert(LocalAlbumEntityCompanion.insert(id: id, name: id, backupSelection: selection));

Future<void> _addToAlbum(Drift db, String assetId, String albumId) =>
    db.into(db.localAlbumAssetEntity).insert(LocalAlbumAssetEntityCompanion.insert(assetId: assetId, albumId: albumId));

Future<void> _insertLocal(Drift db, String id, String checksum, DateTime createdAt) => db
    .into(db.localAssetEntity)
    .insert(
      LocalAssetEntityCompanion.insert(
        id: id,
        name: '$id.jpg',
        type: AssetType.image,
        checksum: Value(checksum),
        createdAt: Value(createdAt),
        updatedAt: Value(createdAt),
      ),
    );

Future<void> _insertRemote(
  Drift db,
  String id,
  String checksum,
  String ownerId,
  DateTime createdAt, {
  AssetVisibility visibility = AssetVisibility.timeline,
  DateTime? deletedAt,
  String? stackId,
}) => db
    .into(db.remoteAssetEntity)
    .insert(
      RemoteAssetEntityCompanion.insert(
        id: id,
        name: '$id.jpg',
        type: AssetType.image,
        checksum: checksum,
        ownerId: ownerId,
        visibility: visibility,
        createdAt: Value(createdAt),
        updatedAt: Value(createdAt),
        deletedAt: Value(deletedAt),
        stackId: Value(stackId),
      ),
    );
