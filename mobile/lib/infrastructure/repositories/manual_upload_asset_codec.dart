import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

abstract final class ManualUploadAssetCodec {
  static Map<String, Object?> encode(LocalAsset asset) => {
    'id': asset.id,
    'name': asset.name,
    'type': asset.type.name,
    'createdAt': asset.createdAt.toUtc().toIso8601String(),
    'updatedAt': asset.updatedAt.toUtc().toIso8601String(),
    'width': asset.width,
    'height': asset.height,
    'durationMs': asset.durationMs,
    'isFavorite': asset.isFavorite,
    'isEdited': asset.isEdited,
    'playbackStyle': asset.playbackStyle.name,
    'orientation': asset.orientation,
    'checksum': asset.checksum,
    'cloudId': asset.cloudId,
    'adjustmentTime': asset.adjustmentTime?.toUtc().toIso8601String(),
    'latitude': asset.latitude,
    'longitude': asset.longitude,
    'livePhotoVideoId': asset.livePhotoVideoId,
  };

  static LocalAsset decode(Map<String, dynamic> value) => LocalAsset(
    id: value['id'] as String,
    name: value['name'] as String,
    type: AssetType.values.byName(value['type'] as String),
    createdAt: DateTime.parse(value['createdAt'] as String),
    updatedAt: DateTime.parse(value['updatedAt'] as String),
    width: value['width'] as int?,
    height: value['height'] as int?,
    durationMs: value['durationMs'] as int?,
    isFavorite: value['isFavorite'] as bool,
    isEdited: value['isEdited'] as bool,
    playbackStyle: AssetPlaybackStyle.values.byName(value['playbackStyle'] as String),
    orientation: value['orientation'] as int,
    checksum: value['checksum'] as String?,
    cloudId: value['cloudId'] as String?,
    adjustmentTime: value['adjustmentTime'] == null ? null : DateTime.parse(value['adjustmentTime'] as String),
    latitude: (value['latitude'] as num?)?.toDouble(),
    longitude: (value['longitude'] as num?)?.toDouble(),
    livePhotoVideoId: value['livePhotoVideoId'] as String?,
  );
}
