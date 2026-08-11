import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/remote_image_api.g.dart',
    swiftOut: 'ios/Runner/Images/RemoteImages.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/images/RemoteImages.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.images', includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum RemoteImagePolicy { cacheOnly, cacheThenNetwork }

enum RemoteImageRequestKind { thumbnail, original }

enum RemoteImageErrorCode {
  cacheMiss,
  mediaNotLocal,
  iCloudUnavailable,
  cancelled,
  timeout,
  serverUnavailable,
  wrongServer,
  unauthorized,
}

class RemoteImageRequest {
  RemoteImageRequest({
    required this.url,
    required this.origin,
    required this.requestId,
    required this.preferEncoded,
    required this.policy,
    required this.kind,
    this.expectedContextGeneration,
  });

  String url;
  String origin;
  int requestId;
  bool preferEncoded;
  RemoteImagePolicy policy;
  RemoteImageRequestKind kind;
  int? expectedContextGeneration;
}

class RemoteImagePayload {
  RemoteImagePayload({required this.pointer, this.length, this.width, this.height, this.rowBytes});

  int pointer;
  int? length;
  int? width;
  int? height;
  int? rowBytes;
}

class RemoteImageResult {
  RemoteImageResult({this.payload, this.error});

  RemoteImagePayload? payload;
  RemoteImageErrorCode? error;
}

class RemoteImageCacheClearRequest {
  RemoteImageCacheClearRequest({required this.requestId});

  int requestId;
}

class RemoteImageCacheClearResult {
  RemoteImageCacheClearResult({this.clearedBytes, this.error});

  int? clearedBytes;
  RemoteImageErrorCode? error;
}

@HostApi()
abstract class RemoteImageApi {
  @async
  RemoteImageResult requestImage(RemoteImageRequest request);

  void cancelRequest(int requestId);

  void cancelAll();

  void dispose();

  @async
  RemoteImageCacheClearResult clearCache(RemoteImageCacheClearRequest request);
}
