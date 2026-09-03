import 'package:drift/drift.dart';
import 'package:drift/native.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/timeline.model.dart';
import 'package:immich_mobile/infrastructure/entities/asset_face.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/person.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/remote_asset.entity.drift.dart';
import 'package:immich_mobile/infrastructure/entities/user.entity.drift.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/timeline.repository.dart';
import 'package:intl/date_symbol_data_local.dart';

void main() {
  const userId = 'user-1';
  const personId = 'person-1';
  const videoId = 'video-1';
  const photoId = 'photo-1';

  late Drift db;
  late DriftTimelineRepository repository;

  setUpAll(() => initializeDateFormatting('en'));

  setUp(() async {
    db = Drift(DatabaseConnection(NativeDatabase.memory(), closeStreamsSynchronously: true));
    repository = DriftTimelineRepository(db);

    await _insertUser(db, userId);
    await _insertUser(db, 'other-user');
    await _insertPerson(db, personId, userId);
    await _insertPerson(db, 'person-2', userId);

    final day = DateTime(2024, 6, 1);
    await _insertRemoteAsset(db, 'other-person-asset', userId, day.add(const Duration(hours: 13)), AssetType.image);
    await _insertRemoteAsset(db, videoId, userId, day.add(const Duration(hours: 12)), AssetType.video);
    await _insertRemoteAsset(db, photoId, userId, day.add(const Duration(hours: 11)), AssetType.image);
    await _insertRemoteAsset(
      db,
      'hidden-asset',
      userId,
      day.add(const Duration(hours: 10)),
      AssetType.video,
      visibility: AssetVisibility.hidden,
    );
    await _insertRemoteAsset(
      db,
      'deleted-asset',
      userId,
      day.add(const Duration(hours: 9)),
      AssetType.video,
      deletedAt: day.add(const Duration(days: 1)),
    );
    await _insertRemoteAsset(db, 'invisible-face-asset', userId, day.add(const Duration(hours: 8)), AssetType.video);
    await _insertRemoteAsset(db, 'deleted-face-asset', userId, day.add(const Duration(hours: 7)), AssetType.video);
    await _insertRemoteAsset(db, 'other-owner-asset', 'other-user', day.add(const Duration(hours: 6)), AssetType.video);

    for (var frame = 0; frame < 25; frame++) {
      await _insertFace(db, 'video-face-$frame', videoId, personId);
    }
    await _insertFace(db, 'photo-face', photoId, personId);
    await _insertFace(db, 'hidden-face', 'hidden-asset', personId);
    await _insertFace(db, 'deleted-face', 'deleted-asset', personId);
    await _insertFace(db, 'invisible-face', 'invisible-face-asset', personId, isVisible: false);
    await _insertFace(
      db,
      'soft-deleted-face',
      'deleted-face-asset',
      personId,
      deletedAt: day.add(const Duration(days: 1)),
    );
    await _insertFace(db, 'other-owner-face', 'other-owner-asset', personId);
    await _insertFace(db, 'other-person-face', 'other-person-asset', 'person-2');
  });

  tearDown(() => db.close());

  test('person timeline counts each matching asset once for ungrouped and day buckets', () async {
    for (final groupBy in [GroupAssetsBy.none, GroupAssetsBy.day]) {
      final buckets = await repository.person(userId, personId, groupBy).bucketSource().first;

      expect(buckets.fold<int>(0, (total, bucket) => total + bucket.assetCount), 2, reason: groupBy.name);
      if (groupBy == GroupAssetsBy.day) {
        expect(buckets, hasLength(1));
        expect((buckets.single as TimeBucket).date, DateTime(2024, 6, 1));
      }
    }
  });

  test('person timeline deduplicates before pagination without deleting frame detections', () async {
    final query = repository.person(userId, personId, GroupAssetsBy.none);

    final firstPage = await query.assetSource(0, 1);
    final secondPage = await query.assetSource(1, 1);
    final endPage = await query.assetSource(2, 1);
    final allAssets = await query.assetSource(0, 10);
    final videoFaceCount =
        await (db.assetFaceEntity.selectOnly()
              ..addColumns([db.assetFaceEntity.id.count()])
              ..where(db.assetFaceEntity.assetId.equals(videoId)))
            .map((row) => row.read(db.assetFaceEntity.id.count())!)
            .getSingle();
    final otherPersonFaceCount =
        await (db.assetFaceEntity.selectOnly()
              ..addColumns([db.assetFaceEntity.id.count()])
              ..where(db.assetFaceEntity.id.equals('other-person-face')))
            .map((row) => row.read(db.assetFaceEntity.id.count())!)
            .getSingle();

    expect(firstPage.map((asset) => asset.remoteId), [videoId]);
    expect(secondPage.map((asset) => asset.remoteId), [photoId]);
    expect(endPage, isEmpty);
    expect(allAssets.map((asset) => asset.remoteId), [videoId, photoId]);
    expect(videoFaceCount, 25);
    expect(otherPersonFaceCount, 1);
  });
}

Future<void> _insertUser(Drift db, String id) =>
    db.into(db.userEntity).insert(UserEntityCompanion.insert(id: id, email: '$id@test.dev', name: id));

Future<void> _insertPerson(Drift db, String id, String ownerId) => db
    .into(db.personEntity)
    .insert(PersonEntityCompanion.insert(id: id, ownerId: ownerId, name: id, isFavorite: false, isHidden: false));

Future<void> _insertRemoteAsset(
  Drift db,
  String id,
  String ownerId,
  DateTime createdAt,
  AssetType type, {
  AssetVisibility visibility = AssetVisibility.timeline,
  DateTime? deletedAt,
}) => db
    .into(db.remoteAssetEntity)
    .insert(
      RemoteAssetEntityCompanion.insert(
        id: id,
        name: '$id.jpg',
        type: type,
        checksum: '$id-checksum',
        ownerId: ownerId,
        visibility: visibility,
        createdAt: Value(createdAt),
        updatedAt: Value(createdAt),
        localDateTime: Value(createdAt),
        deletedAt: Value(deletedAt),
      ),
    );

Future<void> _insertFace(
  Drift db,
  String id,
  String assetId,
  String personId, {
  bool isVisible = true,
  DateTime? deletedAt,
}) => db
    .into(db.assetFaceEntity)
    .insert(
      AssetFaceEntityCompanion.insert(
        id: id,
        assetId: assetId,
        personId: Value(personId),
        imageWidth: 1920,
        imageHeight: 1080,
        boundingBoxX1: 0,
        boundingBoxY1: 0,
        boundingBoxX2: 100,
        boundingBoxY2: 100,
        sourceType: 'video',
        isVisible: Value(isVisible),
        deletedAt: Value(deletedAt),
      ),
    );
