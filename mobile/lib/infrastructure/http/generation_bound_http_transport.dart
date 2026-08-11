import 'dart:async';

import 'package:http/http.dart' as http;
import 'package:logging/logging.dart';

final class GenerationBoundHttpTransport {
  GenerationBoundHttpTransport(this._client, {required this.generation});

  final http.Client _client;
  final int generation;
  final _responses = <_GenerationBoundResponse>{};
  final _pendingSends = <Future<void>>{};
  var _admissionsClosed = false;
  var _invalidated = false;
  var _closed = false;

  static final _log = Logger('GenerationBoundHttpTransport');

  bool owns(http.Client client) => identical(_client, client);

  Future<http.StreamedResponse> send(http.BaseRequest request) async {
    if (_admissionsClosed || _invalidated || _closed) {
      throw _staleRequest(request.url);
    }
    final sendCompletion = Completer<void>();
    _pendingSends.add(sendCompletion.future);
    try {
      final response = await _client.send(request);
      if (_admissionsClosed || _invalidated) {
        await _cancelUnboundResponse(response);
        throw _staleRequest(request.url);
      }
      late final _GenerationBoundResponse tracked;
      tracked = _GenerationBoundResponse(
        response,
        generation: generation,
        requestUrl: request.url,
        onRelease: () => _responses.remove(tracked),
      );
      _responses.add(tracked);
      return tracked.response;
    } catch (error) {
      if ((_admissionsClosed || _invalidated) && error is! http.ClientException) {
        throw _staleRequest(request.url);
      }
      rethrow;
    } finally {
      sendCompletion.complete();
      _pendingSends.remove(sendCompletion.future);
    }
  }

  Future<void> fenceAndDrain({required Duration? timeout}) async {
    _admissionsClosed = true;
    try {
      _closeClientOnce();
    } catch (error, stackTrace) {
      _log.warning('Retired native transport failed to close.', error, stackTrace);
    }
    final cancellations = _responses.map((response) => response.invalidate()).toList(growable: false);
    final pending = _pendingSends.toList(growable: false);
    final drain = Future.wait([...cancellations, ...pending]);
    await (timeout == null ? drain : drain.timeout(timeout));
    _invalidated = true;
  }

  void invalidate() {
    if (_invalidated) return;
    _admissionsClosed = true;
    _invalidated = true;
    for (final response in _responses.toList(growable: false)) {
      unawaited(response.invalidate());
    }
    try {
      _closeClientOnce();
    } catch (error, stackTrace) {
      _log.warning('Retired native transport failed to close.', error, stackTrace);
    }
  }

  http.ClientException _staleRequest(Uri requestUrl) => http.ClientException(
    'Request generation $generation was invalidated by a native transport replacement',
    requestUrl,
  );

  Future<void> _cancelUnboundResponse(http.StreamedResponse response) async {
    final subscription = response.stream.listen(null, onError: (_) {});
    await subscription.cancel();
  }

  void _closeClientOnce() {
    if (_closed) return;
    _closed = true;
    _client.close();
  }
}

final class _GenerationBoundResponse {
  _GenerationBoundResponse(
    this._source, {
    required this.generation,
    required this.requestUrl,
    required void Function() onRelease,
  }) : _onRelease = onRelease {
    _controller = StreamController<List<int>>(
      onListen: _listen,
      onPause: () => _subscription?.pause(),
      onResume: () => _subscription?.resume(),
      onCancel: _cancelFromConsumer,
    );
  }

  final http.StreamedResponse _source;
  final int generation;
  final Uri requestUrl;
  final void Function() _onRelease;
  late final StreamController<List<int>> _controller;
  StreamSubscription<List<int>>? _subscription;
  var _invalidated = false;
  var _released = false;

  http.StreamedResponse get response {
    final source = _source;
    if (source case http.BaseResponseWithUrl(:final url)) {
      return _CanonicalStreamedResponseWithUrl(
        _controller.stream,
        source.statusCode,
        url: url,
        contentLength: source.contentLength,
        request: source.request,
        headers: source.headers,
        isRedirect: source.isRedirect,
        persistentConnection: source.persistentConnection,
        reasonPhrase: source.reasonPhrase,
      );
    }

    return http.StreamedResponse(
      _controller.stream,
      source.statusCode,
      contentLength: source.contentLength,
      request: source.request,
      headers: source.headers,
      isRedirect: source.isRedirect,
      persistentConnection: source.persistentConnection,
      reasonPhrase: source.reasonPhrase,
    );
  }

  void _listen() {
    if (_invalidated) return;
    _subscription = _source.stream.listen(
      (data) {
        if (!_invalidated) _controller.add(data);
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!_invalidated) _controller.addError(error, stackTrace);
      },
      onDone: () {
        if (!_invalidated) unawaited(_controller.close());
        _release();
      },
    );
  }

  Future<void> _cancelFromConsumer() async {
    _invalidated = true;
    try {
      await _subscription?.cancel();
    } finally {
      _release();
    }
  }

  Future<void> invalidate() async {
    if (_invalidated || _released) return;
    _invalidated = true;
    _controller.addError(
      http.ClientException(
        'Response generation $generation was invalidated by a native transport replacement',
        requestUrl,
      ),
    );
    unawaited(_controller.close());
    final subscription = _subscription ??= _source.stream.listen(null, onError: (_) {});
    try {
      await subscription.cancel();
    } finally {
      _release();
    }
  }

  void _release() {
    if (_released) return;
    _released = true;
    _onRelease();
  }
}

final class _CanonicalStreamedResponseWithUrl extends http.StreamedResponse implements http.BaseResponseWithUrl {
  _CanonicalStreamedResponseWithUrl(
    super.stream,
    super.statusCode, {
    required this.url,
    super.contentLength,
    super.request,
    super.headers,
    super.isRedirect,
    super.persistentConnection,
    super.reasonPhrase,
  });

  @override
  final Uri url;
}
