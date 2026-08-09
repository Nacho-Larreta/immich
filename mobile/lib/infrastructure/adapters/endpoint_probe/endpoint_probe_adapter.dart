import 'dart:async';
import 'dart:convert';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_common_header_sanitizer.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';

final class EndpointProbeAdapter implements EndpointProbePort {
  EndpointProbeAdapter({
    required this.transport,
    Map<String, String> commonHeaders = const {},
    String accessToken = '',
    this.candidateTimeout = const Duration(seconds: 3),
    ProbeCommonHeaderSanitizer headerSanitizer = const ProbeCommonHeaderSanitizer(),
  }) : commonHeaders = headerSanitizer.sanitize(commonHeaders),
       authenticationHeaders = accessToken.isEmpty
           ? const {}
           : Map.unmodifiable({'Authorization': 'Bearer $accessToken'}) {
    if (candidateTimeout <= Duration.zero) {
      throw ArgumentError.value(candidateTimeout, 'candidateTimeout', 'Must be positive');
    }
  }

  final ProbeHttpTransportPort transport;
  final Map<String, String> commonHeaders;
  final Map<String, String> authenticationHeaders;
  final Duration candidateTimeout;

  @override
  CancellableRequest<EndpointProbeResult> probe(EndpointProbeRequest request) {
    final operation = _EndpointProbeOperation(
      transport: transport,
      request: request,
      commonHeaders: Map.unmodifiable(commonHeaders),
      authenticationHeaders: Map.unmodifiable(authenticationHeaders),
      candidateTimeout: candidateTimeout,
    );
    operation.start();
    return operation;
  }
}

final class _EndpointProbeOperation implements CancellableRequest<EndpointProbeResult> {
  _EndpointProbeOperation({
    required this.transport,
    required this.request,
    required this.commonHeaders,
    required this.authenticationHeaders,
    required this.candidateTimeout,
  });

  final ProbeHttpTransportPort transport;
  final EndpointProbeRequest request;
  final Map<String, String> commonHeaders;
  final Map<String, String> authenticationHeaders;
  final Duration candidateTimeout;
  final Completer<EndpointProbeResult> _completion = Completer();

  ProbeHttpSessionPort? _session;
  CancellableRequest<ProbeHttpResponse>? _activeRequest;
  Timer? _deadline;
  bool _settled = false;
  bool _sessionClosed = false;

  @override
  Future<EndpointProbeResult> get result => _completion.future;

  void start() {
    try {
      _session = transport.openEphemeralSession(
        ProbeHttpSessionConfiguration(
          timeout: candidateTimeout,
          persistentCookiesEnabled: false,
          cacheEnabled: false,
          redirectPolicy: ProbeHttpRedirectPolicy.sameOriginOnly,
        ),
      );
      _deadline = Timer(candidateTimeout, () {
        unawaited(_finish(const EndpointProbeResult.rejected(OfflineErrorCode.timeout), cancelActiveRequest: true));
      });
      unawaited(_run());
    } on ProbeHttpTransportException {
      unawaited(_finish(const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable)));
    }
  }

  Future<void> _run() async {
    try {
      final probeResult = await _performProbe();
      await _finish(probeResult);
    } on _ProbeStopped {
      return;
    } on FormatException {
      await _finish(const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer));
    } on ProbeHttpTransportException {
      await _finish(const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable));
    }
  }

  Future<EndpointProbeResult> _performProbe() async {
    final discoveryResponse = await _get(request.candidateOrigin.resolve('/.well-known/immich'), commonHeaders);
    if (!_stayedOnCandidateOrigin(discoveryResponse)) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);
    }

    final apiEndpoint = switch (discoveryResponse.statusCode) {
      200 => _apiEndpointFromDiscovery(discoveryResponse.body),
      404 => request.candidateApiEndpoint,
      401 => null,
      _ => null,
    };
    if (discoveryResponse.statusCode == 401) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.unauthorized);
    }
    if (discoveryResponse.statusCode != 200 && discoveryResponse.statusCode != 404) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable);
    }
    if (apiEndpoint == null) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);
    }

    final pingResponse = await _get(_appendPath(apiEndpoint, const ['server', 'ping']), commonHeaders);
    if (!_stayedOnCandidateOrigin(pingResponse)) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);
    }
    final pingFailure = _httpFailure(pingResponse.statusCode);
    if (pingFailure != null) {
      return EndpointProbeResult.rejected(pingFailure);
    }
    if (!_isImmichPing(pingResponse.body)) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);
    }

    final userResponse = await _get(_appendPath(apiEndpoint, const ['users', 'me']), {
      ...commonHeaders,
      ...authenticationHeaders,
    });
    if (!_stayedOnCandidateOrigin(userResponse)) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);
    }
    final userFailure = _httpFailure(userResponse.statusCode);
    if (userFailure != null) {
      return EndpointProbeResult.rejected(userFailure);
    }
    if (_userId(userResponse.body) != request.expectedUserId) {
      return const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer);
    }

    return EndpointProbeResult.validated(
      canonicalOrigin: request.candidateOrigin,
      apiEndpoint: apiEndpoint,
      userId: request.expectedUserId,
      schemePolicy: request.schemePolicy,
    );
  }

  Future<ProbeHttpResponse> _get(Uri uri, Map<String, String> headers) async {
    if (_settled) {
      throw const _ProbeStopped();
    }
    final operation = _session!.get(ProbeHttpRequest(uri: uri, headers: headers));
    _activeRequest = operation;
    final response = await operation.result;
    if (_settled) {
      throw const _ProbeStopped();
    }
    _activeRequest = null;
    return response;
  }

  bool _stayedOnCandidateOrigin(ProbeHttpResponse response) {
    final candidateOrigin = request.candidateOrigin.origin;
    return response.requestUri.origin == candidateOrigin &&
        response.effectiveUri.origin == candidateOrigin &&
        response.redirectChain.every((redirect) => redirect.origin == candidateOrigin);
  }

  Uri? _apiEndpointFromDiscovery(String body) {
    final decoded = jsonDecode(body);
    if (decoded is! Map<String, dynamic>) {
      return null;
    }
    final api = decoded['api'];
    if (api is! Map<String, dynamic>) {
      return null;
    }
    final endpointValue = api['endpoint'];
    if (endpointValue is! String) {
      return null;
    }
    return _sameOriginApiEndpoint(endpointValue);
  }

  Uri? _sameOriginApiEndpoint(String endpointValue) {
    final endpoint = request.candidateOrigin.resolve(endpointValue);
    try {
      validateHttpEndpoint(endpoint, 'endpoint');
    } on ArgumentError {
      return null;
    }
    if (endpoint.origin != request.candidateOrigin.origin) {
      return null;
    }
    final pathSegments = endpoint.pathSegments.where((segment) => segment.isNotEmpty).toList();
    if (pathSegments.isEmpty || pathSegments.last != 'api') {
      return null;
    }
    return Uri(
      scheme: request.candidateOrigin.scheme,
      host: request.candidateOrigin.host,
      port: request.candidateOrigin.hasPort ? request.candidateOrigin.port : null,
      pathSegments: pathSegments,
    );
  }

  @override
  Future<void> cancel() {
    return _finish(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled), cancelActiveRequest: true);
  }

  Future<void> _finish(EndpointProbeResult probeResult, {bool cancelActiveRequest = false}) async {
    if (_settled) {
      return;
    }
    _settled = true;
    _deadline?.cancel();
    if (cancelActiveRequest) {
      await _activeRequest?.cancel();
    }
    await _closeSession();
    _completion.complete(probeResult);
  }

  Future<void> _closeSession() async {
    if (_sessionClosed) {
      return;
    }
    _sessionClosed = true;
    await _session?.close();
  }
}

OfflineErrorCode? _httpFailure(int statusCode) {
  if (statusCode == 401) {
    return OfflineErrorCode.unauthorized;
  }
  return statusCode >= 200 && statusCode < 300 ? null : OfflineErrorCode.serverUnavailable;
}

bool _isImmichPing(String body) {
  final decoded = jsonDecode(body);
  return decoded is Map<String, dynamic> && decoded['res'] == 'pong';
}

String? _userId(String body) {
  final decoded = jsonDecode(body);
  return decoded is Map<String, dynamic> && decoded['id'] is String ? decoded['id'] as String : null;
}

Uri _appendPath(Uri apiEndpoint, List<String> pathSegments) {
  return Uri(
    scheme: apiEndpoint.scheme,
    host: apiEndpoint.host,
    port: apiEndpoint.hasPort ? apiEndpoint.port : null,
    pathSegments: [...apiEndpoint.pathSegments.where((segment) => segment.isNotEmpty), ...pathSegments],
  );
}

final class _ProbeStopped implements Exception {
  const _ProbeStopped();
}
