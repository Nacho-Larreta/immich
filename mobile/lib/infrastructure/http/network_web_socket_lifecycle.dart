import 'dart:async';
import 'dart:typed_data';

import 'package:web_socket/web_socket.dart';

final class NetworkWebSocketFenced implements Exception {
  const NetworkWebSocketFenced();

  @override
  String toString() => 'WebSocket admission is fenced for a network context transition';
}

final class NetworkWebSocketLifecycle {
  final _pendingConnections = <Future<void>>{};
  final _openSockets = <_TrackedWebSocket>{};
  var _admissionsClosed = false;

  Future<WebSocket> connect(Future<WebSocket> Function() start) async {
    if (_admissionsClosed) throw const NetworkWebSocketFenced();
    final settlement = Completer<void>();
    _pendingConnections.add(settlement.future);
    try {
      final socket = await start();
      if (_admissionsClosed) {
        await _closeSocket(socket);
        throw const NetworkWebSocketFenced();
      }
      late final _TrackedWebSocket tracked;
      tracked = _TrackedWebSocket(socket, onClosed: () => _openSockets.remove(tracked));
      _openSockets.add(tracked);
      return tracked;
    } finally {
      settlement.complete();
      _pendingConnections.remove(settlement.future);
    }
  }

  Future<void> fenceAndDrain({required Duration timeout}) async {
    _admissionsClosed = true;
    final closures = _openSockets.map((socket) => socket.fenceAndClose()).toList(growable: false);
    final pending = _pendingConnections.toList(growable: false);
    await Future.wait([...closures, ...pending]).timeout(timeout);
  }
}

final class _TrackedWebSocket implements WebSocket {
  _TrackedWebSocket(this._delegate, {required void Function() onClosed}) : _onClosed = onClosed {
    _events = StreamController<WebSocketEvent>();
    _eventSubscription = _delegate.events.listen(_onEvent, onDone: _onEventsDone);
    _events
      ..onPause = _eventSubscription.pause
      ..onResume = _eventSubscription.resume
      ..onCancel = _eventSubscription.cancel;
  }

  final WebSocket _delegate;
  final void Function() _onClosed;
  late final StreamController<WebSocketEvent> _events;
  late final StreamSubscription<WebSocketEvent> _eventSubscription;
  Future<void>? _closeFuture;
  Future<void>? _eventFence;
  var _fenced = false;
  var _released = false;

  void _release() {
    if (_released) return;
    _released = true;
    _onClosed();
  }

  @override
  Future<void> close([int? code, String? reason]) {
    return _closeFuture ??= _close(code, reason);
  }

  Future<void> fenceAndClose() {
    final eventFence = _fenceEvents();
    return Future.wait([eventFence, close()]);
  }

  Future<void> _fenceEvents() {
    final existing = _eventFence;
    if (existing != null) return existing;
    _fenced = true;
    final cancellation = _eventSubscription.cancel();
    unawaited(_events.close());
    return _eventFence = cancellation;
  }

  Future<void> _close(int? code, String? reason) async {
    try {
      await _delegate.close(code, reason);
    } on WebSocketConnectionClosed {
      return;
    } finally {
      _release();
    }
  }

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => _delegate.protocol;

  @override
  void sendBytes(Uint8List b) {
    if (_fenced) throw const NetworkWebSocketFenced();
    _delegate.sendBytes(b);
  }

  @override
  void sendText(String s) {
    if (_fenced) throw const NetworkWebSocketFenced();
    _delegate.sendText(s);
  }

  void _onEvent(WebSocketEvent event) {
    if (_fenced || _events.isClosed) return;
    _events.add(event);
    if (event is CloseReceived) {
      unawaited(_events.close());
      _release();
    }
  }

  void _onEventsDone() {
    if (!_events.isClosed) unawaited(_events.close());
    _release();
  }
}

Future<void> _closeSocket(WebSocket socket) async {
  try {
    await socket.close();
  } on WebSocketConnectionClosed {
    return;
  }
}
