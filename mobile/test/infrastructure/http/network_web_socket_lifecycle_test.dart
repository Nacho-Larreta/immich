import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/http/network_web_socket_lifecycle.dart';
import 'package:web_socket/web_socket.dart';

void main() {
  test('fence waits for a pending handshake and closes the socket before draining', () async {
    final lifecycle = NetworkWebSocketLifecycle();
    final handshake = Completer<WebSocket>();
    final socket = _ControlledWebSocket();
    final connection = lifecycle.connect(() => handshake.future);

    var drained = false;
    final drain = lifecycle.fenceAndDrain(timeout: const Duration(seconds: 1)).then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    handshake.complete(socket);
    await socket.closeStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    socket.allowClose.complete();
    await expectLater(connection, throwsA(isA<NetworkWebSocketFenced>()));
    await drain;
  });

  test('fence awaits close acknowledgement from an open socket', () async {
    final lifecycle = NetworkWebSocketLifecycle();
    final socket = _ControlledWebSocket();
    await lifecycle.connect(() async => socket);

    var drained = false;
    final drain = lifecycle.fenceAndDrain(timeout: const Duration(seconds: 1)).then((_) => drained = true);
    await socket.closeStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    socket.allowClose.complete();
    await drain;
    expect(drained, isTrue);
  });

  test('fence rejects sends and cuts events before close acknowledgement', () async {
    final lifecycle = NetworkWebSocketLifecycle();
    final delegate = _ControlledWebSocket();
    final socket = await lifecycle.connect(() async => delegate);
    final delivered = <WebSocketEvent>[];
    final eventsDone = Completer<void>();
    socket.events.listen(delivered.add, onDone: eventsDone.complete);

    final drain = lifecycle.fenceAndDrain(timeout: const Duration(seconds: 1));
    await delegate.closeStarted.future;

    expect(() => socket.sendText('stale'), throwsA(isA<NetworkWebSocketFenced>()));
    expect(() => socket.sendBytes(Uint8List.fromList([1])), throwsA(isA<NetworkWebSocketFenced>()));
    delegate.emit(TextDataReceived('stale'));
    await Future<void>.delayed(Duration.zero);

    expect(delivered, isEmpty);
    await eventsDone.future;
    delegate.allowClose.complete();
    await drain;
    expect(delegate.sentTexts, isEmpty);
    expect(delegate.sentBytes, isEmpty);
  });

  test('a close timeout leaves sends and events fenced', () async {
    final lifecycle = NetworkWebSocketLifecycle();
    final delegate = _ControlledWebSocket();
    final socket = await lifecycle.connect(() async => delegate);
    final delivered = <WebSocketEvent>[];
    socket.events.listen(delivered.add);

    await expectLater(
      lifecycle.fenceAndDrain(timeout: const Duration(milliseconds: 10)),
      throwsA(isA<TimeoutException>()),
    );

    expect(() => socket.sendText('stale'), throwsA(isA<NetworkWebSocketFenced>()));
    delegate.emit(TextDataReceived('stale'));
    await Future<void>.delayed(Duration.zero);
    expect(delivered, isEmpty);

    delegate.allowClose.complete();
  });
}

final class _ControlledWebSocket implements WebSocket {
  final closeStarted = Completer<void>();
  final allowClose = Completer<void>();
  final _events = StreamController<WebSocketEvent>.broadcast();
  final sentTexts = <String>[];
  final sentBytes = <Uint8List>[];

  void emit(WebSocketEvent event) => _events.add(event);

  @override
  Future<void> close([int? code, String? reason]) async {
    if (!closeStarted.isCompleted) closeStarted.complete();
    await allowClose.future;
    await _events.close();
  }

  @override
  Stream<WebSocketEvent> get events => _events.stream;

  @override
  String get protocol => '';

  @override
  void sendBytes(Uint8List b) => sentBytes.add(b);

  @override
  void sendText(String s) => sentTexts.add(s);
}
