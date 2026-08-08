import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

enum ProbeHttpRedirectPolicy { sameOriginOnly }

final class ProbeHttpSessionConfiguration {
  const ProbeHttpSessionConfiguration({
    required this.timeout,
    required this.persistentCookiesEnabled,
    required this.cacheEnabled,
    required this.redirectPolicy,
  });

  final Duration timeout;
  final bool persistentCookiesEnabled;
  final bool cacheEnabled;
  final ProbeHttpRedirectPolicy redirectPolicy;
}

final class ProbeHttpRequest {
  ProbeHttpRequest({required this.uri, Map<String, String> headers = const {}}) : headers = Map.unmodifiable(headers) {
    validateHttpResource(uri, 'uri');
  }

  final Uri uri;
  final Map<String, String> headers;
}

final class ProbeHttpResponse {
  ProbeHttpResponse({
    required this.requestUri,
    required this.effectiveUri,
    required this.statusCode,
    this.body = '',
    List<Uri> redirectChain = const [],
  }) : redirectChain = List.unmodifiable(redirectChain);

  final Uri requestUri;
  final Uri effectiveUri;
  final int statusCode;
  final String body;
  final List<Uri> redirectChain;
}

final class ProbeHttpTransportException implements Exception {
  const ProbeHttpTransportException(this.message);

  final String message;

  @override
  String toString() => 'ProbeHttpTransportException: $message';
}

/// Implementations surface every request and close failure as [ProbeHttpTransportException].
abstract interface class ProbeHttpSessionPort {
  CancellableRequest<ProbeHttpResponse> get(ProbeHttpRequest request);

  Future<void> close();
}

/// Implementations surface session creation failures as [ProbeHttpTransportException].
abstract interface class ProbeHttpTransportPort {
  ProbeHttpSessionPort openEphemeralSession(ProbeHttpSessionConfiguration configuration);
}
