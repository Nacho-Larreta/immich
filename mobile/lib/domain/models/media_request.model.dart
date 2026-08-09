import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

enum RemoteMediaPolicy { cacheOnly, cacheThenNetwork }

enum LocalMediaPolicy { localOnly, allowICloud }

enum MediaRequestKind { thumbnail, original }

sealed class LocalMediaRendition {
  const LocalMediaRendition();

  factory LocalMediaRendition.thumbnail({required int widthPx, required int heightPx}) = LocalMediaThumbnailRendition;
  const factory LocalMediaRendition.originalEncoded() = LocalMediaOriginalEncodedRendition;
}

final class LocalMediaThumbnailRendition extends LocalMediaRendition {
  LocalMediaThumbnailRendition({required this.widthPx, required this.heightPx}) {
    if (widthPx <= 0) {
      throw ArgumentError.value(widthPx, 'widthPx', 'Must be positive');
    }
    if (heightPx <= 0) {
      throw ArgumentError.value(heightPx, 'heightPx', 'Must be positive');
    }
  }

  final int widthPx;
  final int heightPx;
}

final class LocalMediaOriginalEncodedRendition extends LocalMediaRendition {
  const LocalMediaOriginalEncodedRendition();
}

final class RemoteMediaRequest {
  RemoteMediaRequest({required this.requestId, required this.resource, required this.policy, required this.kind})
    : origin = resource.originUri {
    if (requestId < 0) {
      throw ArgumentError.value(requestId, 'requestId', 'Must not be negative');
    }
    validateHttpResource(resource, 'resource');
  }

  final int requestId;
  final Uri resource;
  final Uri origin;
  final RemoteMediaPolicy policy;
  final MediaRequestKind kind;
}

final class LocalMediaRequest {
  LocalMediaRequest({
    required this.requestId,
    required this.assetId,
    required this.assetType,
    required this.policy,
    required this.rendition,
  }) {
    if (requestId < 0) {
      throw ArgumentError.value(requestId, 'requestId', 'Must not be negative');
    }
    if (assetId.isEmpty) {
      throw ArgumentError.value(assetId, 'assetId', 'Must not be empty');
    }
    if (assetType != AssetType.image && assetType != AssetType.video) {
      throw ArgumentError.value(assetType, 'assetType', 'Must be image or video');
    }
    switch (rendition) {
      case LocalMediaThumbnailRendition(:final widthPx, :final heightPx):
        if (widthPx <= 0) {
          throw ArgumentError.value(widthPx, 'rendition.widthPx', 'Must be positive');
        }
        if (heightPx <= 0) {
          throw ArgumentError.value(heightPx, 'rendition.heightPx', 'Must be positive');
        }
      case LocalMediaOriginalEncodedRendition():
        break;
    }
  }

  final int requestId;
  final String assetId;
  final AssetType assetType;
  final LocalMediaPolicy policy;
  final LocalMediaRendition rendition;
}

final class MediaRequestProgress {
  MediaRequestProgress({required this.requestId, required this.fraction}) {
    if (requestId < 0) {
      throw ArgumentError.value(requestId, 'requestId', 'Must not be negative');
    }
    if (!fraction.isFinite || fraction < 0 || fraction > 1) {
      throw ArgumentError.value(fraction, 'fraction', 'Must be between zero and one');
    }
  }

  final int requestId;
  final double fraction;
}

extension on Uri {
  Uri get originUri => Uri(scheme: scheme, host: host, port: hasPort ? port : null);
}
