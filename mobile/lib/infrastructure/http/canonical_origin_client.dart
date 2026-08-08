import 'package:http/http.dart' as http;

final class CanonicalOriginClient extends http.BaseClient {
  CanonicalOriginClient(this._delegate, this._requestOriginContext);

  final http.Client _delegate;
  final RequestOriginContext Function() _requestOriginContext;

  @override
  Future<http.StreamedResponse> send(http.BaseRequest request) {
    if (request.url.userInfo.isNotEmpty) {
      throw http.ClientException('Request URLs must not contain user information', request.url);
    }
    final context = _requestOriginContext();
    if (!context.nativeContextConfirmed) {
      throw http.ClientException('Request rejected before the native context was confirmed', request.url);
    }
    if (context.allowedOrigins.isNotEmpty && !context.allows(request.url)) {
      throw http.ClientException('Request rejected outside the active server origins', request.url);
    }
    return _delegate.send(request);
  }

  @override
  void close() {}
}

final class RequestOriginContext {
  const RequestOriginContext._({required this.nativeContextConfirmed, required this.allowedOrigins});

  const RequestOriginContext.uninitialized() : this._(nativeContextConfirmed: false, allowedOrigins: const []);

  const RequestOriginContext.blocked() : this._(nativeContextConfirmed: false, allowedOrigins: const []);

  const RequestOriginContext.cleared() : this._(nativeContextConfirmed: true, allowedOrigins: const []);

  RequestOriginContext.restricted(Iterable<Uri> origins)
    : this._(nativeContextConfirmed: true, allowedOrigins: List.unmodifiable(origins));

  final bool nativeContextConfirmed;
  final List<Uri> allowedOrigins;

  bool allows(Uri request) => allowedOrigins.any((origin) => isExactCanonicalOrigin(request, origin));
}

final class RequestOriginGuard {
  RequestOriginContext _context = const RequestOriginContext.uninitialized();
  var _latestTransition = 0;

  RequestOriginContext get context => _context;

  void fence() {
    _context = const RequestOriginContext.blocked();
  }

  int block() {
    fence();
    return ++_latestTransition;
  }

  bool isCurrent(int transition) => transition == _latestTransition;

  void publish(int transition, RequestOriginContext context) {
    if (isCurrent(transition)) {
      _context = context;
    }
  }
}

Uri canonicalOriginOfEndpoint(Uri endpoint) {
  if (!_isHttpEndpoint(endpoint) || endpoint.hasQuery || endpoint.hasFragment) {
    throw ArgumentError.value(endpoint, 'endpoint', 'Expected an HTTP(S) endpoint without user information or suffix');
  }
  return _canonicalOrigin(endpoint);
}

Uri validateCanonicalOrigin(Uri origin) {
  if (!_isHttpEndpoint(origin) || origin.path.isNotEmpty || origin.hasQuery || origin.hasFragment) {
    throw ArgumentError.value(origin, 'origin', 'Expected an HTTP(S) origin without path, query, or fragment');
  }
  return _canonicalOrigin(origin);
}

bool isExactCanonicalOrigin(Uri request, Uri expected) {
  if ((request.scheme != 'http' && request.scheme != 'https') || request.host.isEmpty || request.userInfo.isNotEmpty) {
    return false;
  }
  return request.scheme.toLowerCase() == expected.scheme.toLowerCase() &&
      request.host.toLowerCase() == expected.host.toLowerCase() &&
      _effectivePort(request) == _effectivePort(expected);
}

bool isWebSocketForCanonicalOrigin(Uri request, Uri expected) {
  final expectedScheme = expected.scheme == 'https' ? 'wss' : 'ws';
  if (request.scheme.toLowerCase() != expectedScheme || request.host.isEmpty || request.userInfo.isNotEmpty) {
    return false;
  }
  return request.host.toLowerCase() == expected.host.toLowerCase() &&
      _webSocketEffectivePort(request) == _effectivePort(expected);
}

int _effectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'https' ? 443 : 80;
}

int _webSocketEffectivePort(Uri uri) {
  if (uri.hasPort) return uri.port;
  return uri.scheme.toLowerCase() == 'wss' ? 443 : 80;
}

bool _isHttpEndpoint(Uri uri) {
  final scheme = uri.scheme.toLowerCase();
  return (scheme == 'http' || scheme == 'https') && uri.host.isNotEmpty && uri.userInfo.isEmpty;
}

Uri _canonicalOrigin(Uri uri) {
  return Uri(scheme: uri.scheme.toLowerCase(), host: uri.host.toLowerCase(), port: _effectivePort(uri));
}
