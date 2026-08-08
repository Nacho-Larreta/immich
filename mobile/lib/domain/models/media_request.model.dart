import 'package:immich_mobile/domain/models/network_uri.model.dart';

enum RemoteMediaPolicy { cacheOnly, cacheThenNetwork }

enum LocalMediaPolicy { localOnly, allowICloud }

enum MediaRequestKind { thumbnail, original }

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
  LocalMediaRequest({required this.requestId, required this.assetId, required this.policy, required this.kind}) {
    if (requestId < 0) {
      throw ArgumentError.value(requestId, 'requestId', 'Must not be negative');
    }
    if (assetId.isEmpty) {
      throw ArgumentError.value(assetId, 'assetId', 'Must not be empty');
    }
  }

  final int requestId;
  final String assetId;
  final LocalMediaPolicy policy;
  final MediaRequestKind kind;
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
