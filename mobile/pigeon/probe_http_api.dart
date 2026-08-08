import 'package:pigeon/pigeon.dart';

@ConfigurePigeon(
  PigeonOptions(
    dartOut: 'lib/platform/probe_http_api.g.dart',
    swiftOut: 'ios/Runner/Core/ProbeHttp.g.swift',
    swiftOptions: SwiftOptions(includeErrorClass: false),
    kotlinOut: 'android/app/src/main/kotlin/app/alextran/immich/core/ProbeHttp.g.kt',
    kotlinOptions: KotlinOptions(package: 'app.alextran.immich.core', includeErrorClass: false),
    dartOptions: DartOptions(),
    dartPackageName: 'immich_mobile',
  ),
)
enum NativeProbeHttpErrorCode {
  invalidRequest,
  sessionNotFound,
  duplicateRequest,
  cancelled,
  timeout,
  redirectRejected,
  bodyTooLarge,
  transportFailure,
}

class NativeProbeHttpSession {
  NativeProbeHttpSession({required this.sessionId, required this.timeoutMilliseconds});

  int sessionId;
  int timeoutMilliseconds;
}

class NativeProbeHttpRequest {
  NativeProbeHttpRequest({
    required this.sessionId,
    required this.requestId,
    required this.url,
    required this.canonicalOrigin,
    required this.headers,
  });

  int sessionId;
  int requestId;
  String url;
  String canonicalOrigin;
  Map<String, String> headers;
}

class NativeProbeHttpResponse {
  NativeProbeHttpResponse({
    required this.requestUrl,
    required this.effectiveUrl,
    required this.statusCode,
    required this.body,
    required this.redirectChain,
  });

  String requestUrl;
  String effectiveUrl;
  int statusCode;
  String body;
  List<String> redirectChain;
}

class NativeProbeHttpResult {
  NativeProbeHttpResult({this.response, this.error});

  NativeProbeHttpResponse? response;
  NativeProbeHttpErrorCode? error;
}

@HostApi()
abstract class ProbeHttpApi {
  void openSession(NativeProbeHttpSession session);

  @async
  NativeProbeHttpResult get(NativeProbeHttpRequest request);

  void cancelRequest(int sessionId, int requestId);

  void closeSession(int sessionId);
}
