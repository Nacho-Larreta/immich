import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';
import 'package:immich_mobile/platform/probe_http_api.g.dart';

abstract interface class ProbeHttpHostApi {
  Future<void> openSession(NativeProbeHttpSession session);

  Future<NativeProbeHttpResult> get(NativeProbeHttpRequest request);

  Future<void> cancelRequest(int sessionId, int requestId);

  Future<void> closeSession(int sessionId);
}

final class PigeonProbeHttpHostApi implements ProbeHttpHostApi {
  PigeonProbeHttpHostApi({ProbeHttpApi? api}) : _api = api ?? ProbeHttpApi();

  final ProbeHttpApi _api;

  @override
  Future<void> openSession(NativeProbeHttpSession session) => _api.openSession(session);

  @override
  Future<NativeProbeHttpResult> get(NativeProbeHttpRequest request) => _api.get(request);

  @override
  Future<void> cancelRequest(int sessionId, int requestId) => _api.cancelRequest(sessionId, requestId);

  @override
  Future<void> closeSession(int sessionId) => _api.closeSession(sessionId);
}

final class NativeProbeHttpTransport implements ProbeHttpTransportPort {
  NativeProbeHttpTransport({ProbeHttpHostApi? api}) : _api = api ?? PigeonProbeHttpHostApi();

  static int _nextSessionId = 0;
  static int _nextRequestId = 0;

  final ProbeHttpHostApi _api;

  @override
  ProbeHttpSessionPort openEphemeralSession(ProbeHttpSessionConfiguration configuration) {
    if (configuration.cacheEnabled || configuration.persistentCookiesEnabled) {
      throw const ProbeHttpTransportException('Native probe sessions must be ephemeral');
    }
    if (configuration.redirectPolicy != ProbeHttpRedirectPolicy.sameOriginOnly) {
      throw const ProbeHttpTransportException('Native probe sessions only allow same-origin redirects');
    }
    if (configuration.timeout <= Duration.zero) {
      throw const ProbeHttpTransportException('Native probe session timeout must be positive');
    }

    final sessionId = ++_nextSessionId;
    final opened = _translatePlatformFailure(
      _api.openSession(
        NativeProbeHttpSession(sessionId: sessionId, timeoutMilliseconds: configuration.timeout.inMilliseconds),
      ),
    );
    return _NativeProbeHttpSession(api: _api, sessionId: sessionId, opened: opened);
  }

  static int nextRequestId() => ++_nextRequestId;
}

final class _NativeProbeHttpSession implements ProbeHttpSessionPort {
  _NativeProbeHttpSession({required this.api, required this.sessionId, required this.opened});

  final ProbeHttpHostApi api;
  final int sessionId;
  final Future<void> opened;
  bool _closed = false;
  Future<void>? _closeFuture;

  @override
  CancellableRequest<ProbeHttpResponse> get(ProbeHttpRequest request) {
    if (_closed) {
      throw const ProbeHttpTransportException('Native probe session is closed');
    }
    final operation = _NativeProbeHttpRequest(
      api: api,
      opened: opened,
      sessionId: sessionId,
      requestId: NativeProbeHttpTransport.nextRequestId(),
      request: request,
    );
    operation.start();
    return operation;
  }

  @override
  Future<void> close() {
    if (_closeFuture case final future?) {
      return future;
    }
    _closed = true;
    return _closeFuture = _close();
  }

  Future<void> _close() async {
    try {
      await opened;
    } on ProbeHttpTransportException {
      return;
    }
    await _translatePlatformFailure(api.closeSession(sessionId));
  }
}

final class _NativeProbeHttpRequest implements CancellableRequest<ProbeHttpResponse> {
  _NativeProbeHttpRequest({
    required this.api,
    required this.opened,
    required this.sessionId,
    required this.requestId,
    required this.request,
  });

  final ProbeHttpHostApi api;
  final Future<void> opened;
  final int sessionId;
  final int requestId;
  final ProbeHttpRequest request;
  final Completer<ProbeHttpResponse> _completion = Completer();
  bool _cancelled = false;
  Future<void>? _cancelFuture;

  @override
  Future<ProbeHttpResponse> get result => _completion.future;

  void start() {
    unawaited(_run());
  }

  Future<void> _run() async {
    try {
      await opened;
      if (_cancelled) {
        return _completeError(const ProbeHttpTransportException('Native probe request was cancelled'));
      }
      final nativeResult = await _translatePlatformFailure(
        api.get(
          NativeProbeHttpRequest(
            sessionId: sessionId,
            requestId: requestId,
            url: request.uri.toString(),
            canonicalOrigin: request.uri.origin,
            headers: request.headers,
          ),
        ),
      );
      if (_cancelled) {
        return _completeError(const ProbeHttpTransportException('Native probe request was cancelled'));
      }
      final error = nativeResult.error;
      if (error != null) {
        return _completeError(ProbeHttpTransportException('Native probe failed: ${error.name}'));
      }
      final response = nativeResult.response;
      if (response == null) {
        return _completeError(const ProbeHttpTransportException('Native probe returned no response'));
      }
      _complete(
        ProbeHttpResponse(
          requestUri: _parseUri(response.requestUrl, 'request URL'),
          effectiveUri: _parseUri(response.effectiveUrl, 'effective URL'),
          statusCode: response.statusCode,
          body: response.body,
          redirectChain: response.redirectChain.map((value) => _parseUri(value, 'redirect URL')).toList(),
        ),
      );
    } on ProbeHttpTransportException catch (error, stackTrace) {
      _completeError(error, stackTrace);
    } on Object catch (error, stackTrace) {
      _completeError(ProbeHttpTransportException('Native probe failed: $error'), stackTrace);
    }
  }

  @override
  Future<void> cancel() {
    if (_cancelFuture case final future?) {
      return future;
    }
    _cancelled = true;
    _completeError(const ProbeHttpTransportException('Native probe request was cancelled'));
    return _cancelFuture = _cancelNative();
  }

  Future<void> _cancelNative() async {
    try {
      await opened;
      await _translatePlatformFailure(api.cancelRequest(sessionId, requestId));
    } on ProbeHttpTransportException {
      return;
    }
  }

  void _complete(ProbeHttpResponse response) {
    if (!_completion.isCompleted) {
      _completion.complete(response);
    }
  }

  void _completeError(ProbeHttpTransportException error, [StackTrace? stackTrace]) {
    if (!_completion.isCompleted) {
      _completion.completeError(error, stackTrace ?? StackTrace.current);
    }
  }

  static Uri _parseUri(String value, String field) {
    final uri = Uri.tryParse(value);
    if (uri == null || !uri.hasScheme || !uri.hasAuthority) {
      throw ProbeHttpTransportException('Native probe returned an invalid $field');
    }
    return uri;
  }
}

Future<T> _translatePlatformFailure<T>(Future<T> operation) async {
  try {
    return await operation;
  } on ProbeHttpTransportException {
    rethrow;
  } on Object catch (error) {
    throw ProbeHttpTransportException('Native probe platform channel failed: $error');
  }
}
