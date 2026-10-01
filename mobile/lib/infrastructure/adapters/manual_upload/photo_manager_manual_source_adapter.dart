import 'package:immich_mobile/domain/interfaces/manual_upload_source.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/local_asset.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:path/path.dart' as p;

final class PhotoManagerManualSourceAdapter implements ManualUploadSourcePort {
  const PhotoManagerManualSourceAdapter(this._localAssets, this._storage, this._media);

  final DriftLocalAssetRepository _localAssets;
  final StorageRepository _storage;
  final AssetMediaRepository _media;

  @override
  Future<ManualUploadSource?> load(String localAssetId) async {
    final asset = await _localAssets.getById(localAssetId);
    if (asset == null) return null;
    final entity = await _storage.getAssetEntityForAsset(asset);
    if (entity == null) return null;
    final locallyAvailable = await _storage.isAssetAvailableLocally(asset.id);
    final useCloud = !locallyAvailable && CurrentPlatform.isIOS;
    final primary = useCloud ? await _storage.loadFileFromCloud(asset.id) : await _storage.getFileForAsset(asset.id);
    if (primary == null) return null;
    final motion = entity.isLivePhoto
        ? useCloud
              ? await _storage.loadMotionFileFromCloud(asset.id)
              : await _storage.getMotionFileForAsset(asset)
        : null;
    if (entity.isLivePhoto && motion == null) return null;
    final originalName = await _media.getOriginalFilename(asset.id) ?? asset.name;
    final normalizedName = _originalFileName(originalName, asset);
    return ManualUploadSource(
      asset: asset,
      isLivePhoto: entity.isLivePhoto,
      primaryBorrowedPath: primary.path,
      primaryOriginalFileName: entity.isLivePhoto
          ? p.setExtension(normalizedName, p.extension(primary.path))
          : normalizedName,
      motionBorrowedPath: motion?.path,
      motionOriginalFileName: motion == null ? null : p.setExtension(normalizedName, p.extension(motion.path)),
    );
  }

  String _originalFileName(String name, LocalAsset asset) {
    final safeName = p.basename(name);
    return p.extension(safeName).isEmpty ? p.setExtension(safeName, p.extension(asset.name)) : safeName;
  }
}
