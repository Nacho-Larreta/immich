import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/local_image_api.g.dart',
    swiftOut: 'ios/Runner/Images/LocalImages.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/images/LocalImages.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.images'),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum LocalImagePolicy { localOnly, allowICloud }

enum LocalImageRequestKind { thumbnail, original }

enum LocalImageErrorCode {
  cacheMiss,
  mediaNotLocal,
  iCloudUnavailable,
  cancelled,
  timeout,
  serverUnavailable,
  wrongServer,
  unauthorized,
}

class LocalImageRequest {
  LocalImageRequest({
    required this.assetId,
    required this.requestId,
    required this.width,
    required this.height,
    required this.isVideo,
    required this.preferEncoded,
    required this.policy,
    required this.kind,
  });

  String assetId;
  int requestId;
  int width;
  int height;
  bool isVideo;
  bool preferEncoded;
  LocalImagePolicy policy;
  LocalImageRequestKind kind;
}

class LocalImageThumbhashRequest {
  LocalImageThumbhashRequest({required this.thumbhash, required this.requestId});

  String thumbhash;
  int requestId;
}

class LocalImagePayload {
  LocalImagePayload({required this.pointer, this.length, this.width, this.height, this.rowBytes});

  int pointer;
  int? length;
  int? width;
  int? height;
  int? rowBytes;
}

class LocalImageResult {
  LocalImageResult({this.payload, this.error});

  LocalImagePayload? payload;
  LocalImageErrorCode? error;
}

class LocalImageProgress {
  LocalImageProgress({required this.requestId, required this.fraction});

  int requestId;
  double fraction;
}

@HostApi()
abstract class LocalImageApi {
  @async
  LocalImageResult requestImage(LocalImageRequest request);

  void cancelRequest(int requestId);

  void cancelAll();

  void dispose();

  @async
  LocalImageResult getThumbhash(LocalImageThumbhashRequest request);
}

@FlutterApi()
abstract class LocalImageFlutterApi {
  void onProgress(LocalImageProgress progress);
}
