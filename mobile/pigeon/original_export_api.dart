import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/original_export_api.g.dart',
    swiftOut: 'ios/Runner/Share/OriginalExport.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/share/OriginalExport.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.share', includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum OriginalExportPolicy { localOnly, allowICloud }

enum OriginalExportErrorCode {
  assetMissing,
  mediaNotLocal,
  iCloudUnavailable,
  cancelled,
  timeout,
  unauthorized,
  wrongServer,
  serverUnavailable,
  httpFailure,
  storageUnavailable,
  writeFailed,
  cleanupFailed,
  leaseNotFound,
  platformUnsupported,
}

class LocalOriginalExportRequest {
  LocalOriginalExportRequest({
    required this.requestId,
    required this.assetId,
    required this.suggestedName,
    required this.policy,
  });

  int requestId;
  String assetId;
  String suggestedName;
  OriginalExportPolicy policy;
}

class RemoteOriginalExportRequest {
  RemoteOriginalExportRequest({
    required this.requestId,
    required this.url,
    required this.origin,
    required this.suggestedName,
  });

  int requestId;
  String url;
  String origin;
  String suggestedName;
}

class OriginalExportResult {
  OriginalExportResult({this.path, this.leaseToken, this.error});

  String? path;
  String? leaseToken;
  OriginalExportErrorCode? error;
}

class OriginalExportReleaseResult {
  OriginalExportReleaseResult({this.error});

  OriginalExportErrorCode? error;
}

class OriginalExportProgress {
  OriginalExportProgress({required this.requestId, required this.fraction});

  int requestId;
  double fraction;
}

@HostApi()
abstract class OriginalExportApi {
  @async
  OriginalExportResult exportLocal(LocalOriginalExportRequest request);

  @async
  OriginalExportResult exportRemote(RemoteOriginalExportRequest request);

  @async
  void cancelRequest(int requestId);

  @async
  void cancelAll();

  @async
  void dispose();

  @async
  OriginalExportReleaseResult releaseLease(String leaseToken);
}

@FlutterApi()
abstract class OriginalExportFlutterApi {
  void onProgress(OriginalExportProgress progress);
}
