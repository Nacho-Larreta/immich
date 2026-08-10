import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/providers/infrastructure/people.provider.dart';

void main() {
  final remoteAsset = RemoteAsset(
    id: 'asset',
    name: 'asset.jpg',
    checksum: 'checksum',
    type: AssetType.image,
    ownerId: 'current-viewer',
    createdAt: DateTime(2024),
    updatedAt: DateTime(2024),
    isFavorite: false,
    isEdited: false,
  );

  test('people cache query is scoped to the matching current viewer', () {
    final query = scopedAssetPeopleQuery(
      asset: remoteAsset,
      viewerId: 'current-viewer',
      access: const ServerAccessPolicy.offline(),
    );

    expect(query, (assetId: 'asset', ownerId: 'current-viewer'));
  });

  test('people cache query is not constructed without valid cached-read scope', () {
    expect(
      scopedAssetPeopleQuery(asset: remoteAsset, viewerId: null, access: const ServerAccessPolicy.offline()),
      isNull,
    );
    expect(
      scopedAssetPeopleQuery(
        asset: remoteAsset,
        viewerId: 'current-viewer',
        access: const ServerAccessPolicy.unconfigured(),
      ),
      isNull,
    );
  });

  test('people cache query fails closed for an asset owned by another identity', () {
    final foreignAsset = remoteAsset.copyWith(ownerId: 'asset-owner');

    expect(
      scopedAssetPeopleQuery(
        asset: foreignAsset,
        viewerId: 'current-viewer',
        access: const ServerAccessPolicy.offline(),
      ),
      isNull,
    );
  });
}
