import 'dart:io';

import 'package:device_info_plus/device_info_plus.dart';
import 'package:immich_mobile/domain/interfaces/local_asset_management.interface.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:logging/logging.dart';
import 'package:photo_manager/photo_manager.dart';

final class PhotoManagerLocalAssetManagementAdapter implements LocalAssetManagementPort {
  PhotoManagerLocalAssetManagementAdapter({DeviceInfoPlugin? deviceInfo})
    : _deviceInfo = deviceInfo ?? DeviceInfoPlugin();

  final DeviceInfoPlugin _deviceInfo;
  final Logger _log = Logger('PhotoManagerLocalAssetManagementAdapter');

  @override
  Future<List<String>> deleteAll(List<String> assetIds) async {
    if (CurrentPlatform.isAndroid && await _androidSupportsTrash()) {
      return PhotoManager.editor.android.moveToTrash(
        assetIds.map((id) => AssetEntity(id: id, width: 1, height: 1, typeInt: 0)).toList(),
      );
    }
    return PhotoManager.editor.deleteWithIds(assetIds);
  }

  @override
  Future<String?> getOriginalFilename(String assetId) async {
    final entity = await AssetEntity.fromId(assetId);
    if (entity == null) {
      return null;
    }
    try {
      final filename = await entity.titleAsync;
      return filename.isEmpty ? null : filename;
    } on Object catch (error, stackTrace) {
      _log.warning('Failed to read the original filename for a local asset', error, stackTrace);
      return null;
    }
  }

  Future<bool> _androidSupportsTrash() async {
    if (!Platform.isAndroid) {
      return false;
    }
    return (await _deviceInfo.androidInfo).version.sdkInt >= 31;
  }
}
