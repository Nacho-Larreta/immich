final class ProbeCommonHeaderSanitizer {
  const ProbeCommonHeaderSanitizer();

  static const _allowedHeaders = {
    'accept',
    'accept-language',
    'baggage',
    'traceparent',
    'tracestate',
    'user-agent',
    'x-request-id',
  };

  static const _forbiddenHeaders = {
    'authorization',
    'connection',
    'cookie',
    'keep-alive',
    'proxy-authenticate',
    'proxy-authorization',
    'set-cookie',
    'te',
    'trailer',
    'transfer-encoding',
    'upgrade',
    'x-api-key',
  };

  Map<String, String> sanitize(Map<String, String> headers) {
    final sanitized = <String, String>{};
    for (final MapEntry(:key, :value) in headers.entries) {
      final normalizedName = key.trim().toLowerCase();
      if (_forbiddenHeaders.contains(normalizedName) || !_allowedHeaders.contains(normalizedName)) {
        continue;
      }
      sanitized[key] = value;
    }
    return Map.unmodifiable(sanitized);
  }
}
