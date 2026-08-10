import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/person.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/server_access.model.dart';
import 'package:immich_mobile/domain/services/people.service.dart';
import 'package:immich_mobile/infrastructure/repositories/people.repository.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/repositories/person_api.repository.dart';

final driftPeopleRepositoryProvider = Provider<DriftPeopleRepository>(
  (ref) => DriftPeopleRepository(ref.watch(driftProvider)),
);

final driftPeopleServiceProvider = Provider<DriftPeopleService>(
  (ref) => DriftPeopleService(ref.watch(driftPeopleRepositoryProvider), ref.watch(personApiRepositoryProvider)),
);

typedef AssetPeopleQuery = ({String assetId, String ownerId});

AssetPeopleQuery? scopedAssetPeopleQuery({
  required BaseAsset asset,
  required String? viewerId,
  required ServerAccessPolicy access,
}) {
  if (asset is! RemoteAsset ||
      viewerId == null ||
      asset.ownerId != viewerId ||
      !access.allows(ServerCapability.cachedRead)) {
    return null;
  }
  return (assetId: asset.id, ownerId: viewerId);
}

final driftPeopleAssetProvider = FutureProvider.family<List<DriftPerson>, AssetPeopleQuery>((ref, query) async {
  final service = ref.watch(driftPeopleServiceProvider);
  return service.getAssetPeople(query.assetId, query.ownerId);
});

final driftGetAllPeopleProvider = FutureProvider.family<List<DriftPerson>, String>((ref, ownerId) async {
  final service = ref.watch(driftPeopleServiceProvider);
  return service.getAllPeople(ownerId);
});
