import 'dart:async';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/infrastructure/http/canonical_origin_client.dart';

void main() {
  test('delegate replacement preserves client identity and routes only future requests to the new transport', () async {
    final firstTransport = _TrackedClient('anonymous');
    final authenticatedTransport = _TrackedClient('authenticated');
    final client = CanonicalOriginClient(
      firstTransport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );

    expect((await client.get(Uri.parse('https://photos.test/api/auth/login'))).body, 'anonymous');

    client.replaceDelegate(authenticatedTransport);

    expect((await client.get(Uri.parse('https://photos.test/api/users/me'))).body, 'authenticated');
    expect(firstTransport.paths, ['/api/auth/login']);
    expect(authenticatedTransport.paths, ['/api/users/me']);
  });

  test('replacement rejects a request still awaiting the retired transport', () async {
    final releaseFirstRequest = Completer<void>();
    final firstTransport = _TrackedClient('first', gate: releaseFirstRequest);
    final secondTransport = _TrackedClient('second');
    final client = CanonicalOriginClient(
      firstTransport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );

    final inFlight = client.get(Uri.parse('https://photos.test/api/assets/first'));
    await firstTransport.requestStarted.future;

    client.replaceDelegate(secondTransport);
    expect(firstTransport.closeCalls, 1);
    expect((await client.get(Uri.parse('https://photos.test/api/assets/second'))).body, 'second');

    releaseFirstRequest.complete();
    await expectLater(inFlight, throwsA(isA<ClientException>()));
  });

  test('fence tracks a POST from admission and waits for its pending native task', () async {
    final transport = _PendingTaskCreationClient();
    final client = CanonicalOriginClient(
      transport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final request = Request('POST', Uri.parse('https://photos.test/api/assets'))..body = 'payload';
    final inFlight = client.send(request);
    await transport.sendAccepted.future;

    var drained = false;
    final drain = client.fenceAndDrain(timeout: const Duration(seconds: 1)).then((_) => drained = true);
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);
    await expectLater(client.get(Uri.parse('https://photos.test/api/assets/next')), throwsA(isA<ClientException>()));

    transport.allowTaskCreation.complete();
    await expectLater(inFlight, throwsA(isA<ClientException>()));
    await drain;

    expect(transport.closeCalls, 1);
  });

  test('fence awaits asynchronous cancellation of an active response', () async {
    final transport = _BlockingCancellationClient();
    final client = CanonicalOriginClient(
      transport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets')));
    final responseFailure = expectLater(response.stream, emitsError(isA<ClientException>()));

    var drained = false;
    final drain = client.fenceAndDrain(timeout: const Duration(seconds: 1)).then((_) => drained = true);
    await transport.cancelStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    transport.allowCancellation.complete();
    await drain;
    await responseFailure;
  });

  test('fence cancels a native response before its body is listened to', () async {
    final transport = _BlockingCancellationClient();
    final client = CanonicalOriginClient(
      transport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    await client.send(Request('GET', Uri.parse('https://photos.test/api/assets')));

    var drained = false;
    final drain = client.fenceAndDrain(timeout: const Duration(seconds: 1)).then((_) => drained = true);
    await transport.cancelStarted.future;
    await Future<void>.delayed(Duration.zero);
    expect(drained, isFalse);

    transport.allowCancellation.complete();
    await drain;
  });

  test('replacement rejects a retired response mid-body and drops its late bytes', () async {
    final firstTransport = _ControlledStreamClient();
    final client = CanonicalOriginClient(
      firstTransport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets/first')));
    final body = response.stream.bytesToString();
    final staleBody = expectLater(body, throwsA(isA<ClientException>()));
    firstTransport.controller.add(utf8.encode('before'));

    client.replaceDelegate(_TrackedClient('second'));
    firstTransport.controller.add(utf8.encode('late'));
    await firstTransport.controller.close();

    await staleBody;
    expect(firstTransport.closeCalls, 1);
  });

  test('replacement from onData rejects the retired response without reentrant delivery', () async {
    final firstTransport = _SynchronousControlledStreamClient();
    final client = CanonicalOriginClient(
      firstTransport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets/first')));
    final errors = <Object>[];
    final completed = Completer<void>();
    var sourceAddReturned = false;
    var replacementWasReentrant = false;
    response.stream.listen(
      (_) {
        replacementWasReentrant = !sourceAddReturned;
        client.replaceDelegate(_TrackedClient('second'));
      },
      onError: (Object error) => errors.add(error),
      onDone: completed.complete,
    );

    firstTransport.controller.add(utf8.encode('before'));
    sourceAddReturned = true;
    await completed.future.timeout(const Duration(seconds: 1));

    expect(replacementWasReentrant, isFalse);
    expect(errors, [isA<ClientException>()]);
    expect(firstTransport.closeCalls, 1);
  });

  test('a throwing transport close cannot skip response invalidation or release', () async {
    final firstTransport = _ThrowingCloseClient();
    final client = CanonicalOriginClient(
      firstTransport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets/first')));
    final staleResponse = expectLater(response.stream, emitsError(isA<ClientException>()));

    expect(() => client.replaceDelegate(_TrackedClient('second')), returnsNormally);

    await staleResponse;
    expect(firstTransport.closeCalls, 1);
  });

  test('forwards a non-terminal stream error and releases only when the response completes', () async {
    final transport = _ControlledStreamClient();
    final client = CanonicalOriginClient(
      transport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets')));
    final events = expectLater(
      response.stream,
      emitsInOrder([utf8.encode('one'), emitsError(isA<StateError>()), utf8.encode('two'), emitsDone]),
    );

    transport.controller
      ..add(utf8.encode('one'))
      ..addError(StateError('recoverable'))
      ..add(utf8.encode('two'));
    await transport.controller.close();
    await events;

    client.replaceDelegate(_TrackedClient('next'));
    expect(transport.closeCalls, 1);
  });

  test('consumer cancellation releases the response even when upstream cancellation fails', () async {
    final transport = _CancelFailingClient();
    final client = CanonicalOriginClient(
      transport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets')));
    final subscription = response.stream.listen((_) {});

    await expectLater(subscription.cancel(), throwsA(isA<StateError>()));
    client.replaceDelegate(_TrackedClient('next'));

    expect(transport.closeCalls, 1);
  });

  test('replacement invalidates two active responses and closes their delegate exactly once', () async {
    final transport = _MultipleStreamClient(2);
    final client = CanonicalOriginClient(
      transport,
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );
    final first = await client.send(Request('GET', Uri.parse('https://photos.test/api/first')));
    final second = await client.send(Request('GET', Uri.parse('https://photos.test/api/second')));
    final firstEvents = expectLater(first.stream, emitsError(isA<ClientException>()));
    final secondEvents = expectLater(second.stream, emitsError(isA<ClientException>()));

    client.replaceDelegate(_TrackedClient('next'));
    for (final controller in transport.controllers) {
      await controller.close();
    }

    await Future.wait([firstEvents, secondEvents]);
    expect(transport.closeCalls, 1);
  });

  test('preserves the final URL capability returned by the native transport', () async {
    final finalUrl = Uri.parse('https://photos.test/api/assets?cursor=next');
    final client = CanonicalOriginClient(
      _ResponseClient(_StreamedResponseWithUrl(Stream.value(const []), 200, url: finalUrl)),
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );

    final response = await client.send(Request('GET', Uri.parse('https://photos.test/api/assets')));

    expect(response, isA<BaseResponseWithUrl>());
    expect((response as BaseResponseWithUrl).url, finalUrl);
  });

  test('allows requests with the exact scheme host and effective port', () async {
    late Uri sentUri;
    late bool followedRedirects;
    final client = CanonicalOriginClient(
      MockClient((request) async {
        sentUri = request.url;
        followedRedirects = request.followRedirects;
        return Response('', 200);
      }),
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );

    await client.get(Uri.parse('https://PHOTOS.test:443/family/api/assets'));

    expect(sentUri.path, '/family/api/assets');
    expect(followedRedirects, isFalse);
  });

  for (final rejected in [
    'http://photos.test/api',
    'https://other.test/api',
    'https://photos.test:444/api',
    'https://user@photos.test/api',
  ]) {
    test('rejects $rejected before native transport', () async {
      var transportCalls = 0;
      final client = CanonicalOriginClient(
        MockClient((_) async {
          transportCalls++;
          return Response('', 200);
        }),
        () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
      );

      await expectLater(client.get(Uri.parse(rejected)), throwsA(isA<ClientException>()));
      expect(transportCalls, 0);
    });
  }

  test('allows an unauthenticated request after native context clearing is confirmed', () async {
    var transportCalls = 0;
    final client = CanonicalOriginClient(
      MockClient((_) async {
        transportCalls++;
        return Response('', 200);
      }),
      () => const RequestOriginContext.cleared(),
    );

    await client.get(Uri.parse('https://login-candidate.test/api/server/ping'));

    expect(transportCalls, 1);
  });

  test('rejects requests while native context state is uninitialized', () async {
    final client = CanonicalOriginClient(
      MockClient((_) async => Response('', 200)),
      () => const RequestOriginContext.uninitialized(),
    );

    await expectLater(client.get(Uri.parse('https://photos.test/api')), throwsA(isA<ClientException>()));
  });

  test('rejects concurrent requests while a native bridge transition is pending', () async {
    final guard = RequestOriginGuard();
    final client = CanonicalOriginClient(MockClient((_) async => Response('', 200)), () => guard.context);
    final transition = guard.block();
    final bridge = Completer<void>();
    final replacement = (() async {
      await bridge.future;
      guard.publish(transition, RequestOriginContext.restricted([Uri.parse('https://photos.test')]));
    })();

    await expectLater(client.get(Uri.parse('https://photos.test/api')), throwsA(isA<ClientException>()));
    bridge.complete();
    await replacement;
    expect((await client.get(Uri.parse('https://photos.test/api'))).statusCode, 200);
  });

  test('keeps requests blocked when the native bridge transition fails', () async {
    final guard = RequestOriginGuard();
    final client = CanonicalOriginClient(MockClient((_) async => Response('', 200)), () => guard.context);
    guard.block();

    await expectLater(client.get(Uri.parse('https://photos.test/api')), throwsA(isA<ClientException>()));
    expect(guard.context.nativeContextConfirmed, isFalse);
  });

  test('does not publish an older queued transition over a newer fence', () {
    final guard = RequestOriginGuard();
    final older = guard.block();
    final newer = guard.block();

    guard.publish(older, RequestOriginContext.restricted([Uri.parse('https://old.test')]));

    expect(guard.context.nativeContextConfirmed, isFalse);
    expect(guard.isCurrent(newer), isTrue);
  });

  test('logout block prevents a delayed native replacement from reopening requests', () async {
    final guard = RequestOriginGuard();
    final nativeReply = Completer<void>();
    final replacement = guard.block();
    final delayedPublication = (() async {
      await nativeReply.future;
      guard.publish(replacement, RequestOriginContext.restricted([Uri.parse('https://stale.test')]));
    })();

    guard.invalidate();
    nativeReply.complete();
    await delayedPublication;

    expect(guard.context.nativeContextConfirmed, isFalse);
    expect(guard.context.allows(Uri.parse('https://stale.test/api')), isFalse);
  });

  test('safety fence does not invalidate a newer queued login transition', () {
    final guard = RequestOriginGuard();
    final login = guard.block();

    guard.fence();
    guard.publish(login, RequestOriginContext.restricted([Uri.parse('https://new.test')]));

    expect(guard.context.allows(Uri.parse('https://new.test/api')), isTrue);
  });

  test('supports the legacy set of exact auxiliary origins', () async {
    final requests = <Uri>[];
    final client = CanonicalOriginClient(
      MockClient((request) async {
        requests.add(request.url);
        return Response('', 200);
      }),
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test'), Uri.parse('http://photos.lan:2283')]),
    );

    await client.get(Uri.parse('http://photos.lan:2283/api/users/me'));

    expect(requests, [Uri.parse('http://photos.lan:2283/api/users/me')]);
  });

  test('canonical endpoint helper keeps paths out of the resulting origin', () {
    expect(
      canonicalOriginOfEndpoint(Uri.parse('https://photos.test:443/family/api')),
      Uri.parse('https://photos.test'),
    );
  });

  for (final rejected in [
    'https://photos.test/',
    'https://photos.test/api',
    'https://photos.test?mode=api',
    'https://photos.test?',
    'https://photos.test#api',
    'https://photos.test#',
    'https://user@photos.test',
    'ftp://photos.test',
  ]) {
    test('strict canonical origin rejects $rejected', () {
      expect(() => validateCanonicalOrigin(Uri.parse(rejected)), throwsArgumentError);
    });
  }

  test('matches websocket scheme host and effective port to canonical HTTP origin', () {
    expect(
      isWebSocketForCanonicalOrigin(Uri.parse('wss://photos.test/socket.io'), Uri.parse('https://photos.test')),
      isTrue,
    );
    expect(
      isWebSocketForCanonicalOrigin(Uri.parse('ws://photos.test/socket.io'), Uri.parse('https://photos.test')),
      isFalse,
    );
  });
}

final class _TrackedClient extends BaseClient {
  _TrackedClient(this.label, {this.gate});

  final String label;
  final Completer<void>? gate;
  final requestStarted = Completer<void>();
  final paths = <String>[];
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    paths.add(request.url.path);
    if (!requestStarted.isCompleted) {
      requestStarted.complete();
    }
    await gate?.future;
    return StreamedResponse(Stream.value(utf8.encode(label)), 200);
  }

  @override
  void close() {
    closeCalls++;
  }
}

final class _PendingTaskCreationClient extends BaseClient {
  final sendAccepted = Completer<void>();
  final allowTaskCreation = Completer<void>();
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async {
    sendAccepted.complete();
    await allowTaskCreation.future;
    return StreamedResponse(Stream.value(const <int>[]), 200);
  }

  @override
  void close() => closeCalls++;
}

final class _BlockingCancellationClient extends BaseClient {
  final cancelStarted = Completer<void>();
  final allowCancellation = Completer<void>();

  late final StreamController<List<int>> _controller = StreamController<List<int>>(
    onCancel: () async {
      cancelStarted.complete();
      await allowCancellation.future;
    },
  );

  @override
  Future<StreamedResponse> send(BaseRequest request) async => StreamedResponse(_controller.stream, 200);
}

final class _ControlledStreamClient extends BaseClient {
  final controller = StreamController<List<int>>();
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async => StreamedResponse(controller.stream, 200);

  @override
  void close() => closeCalls++;
}

final class _SynchronousControlledStreamClient extends BaseClient {
  final controller = StreamController<List<int>>(sync: true);
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async => StreamedResponse(controller.stream, 200);

  @override
  void close() => closeCalls++;
}

final class _CancelFailingClient extends BaseClient {
  _CancelFailingClient() {
    controller = StreamController<List<int>>(onCancel: () => Future<void>.error(StateError('cancel failed')));
  }

  late final StreamController<List<int>> controller;
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async => StreamedResponse(controller.stream, 200);

  @override
  void close() => closeCalls++;
}

final class _ThrowingCloseClient extends BaseClient {
  final controller = StreamController<List<int>>();
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async => StreamedResponse(controller.stream, 200);

  @override
  void close() {
    closeCalls++;
    throw StateError('close failed');
  }
}

final class _MultipleStreamClient extends BaseClient {
  _MultipleStreamClient(int count) : controllers = List.generate(count, (_) => StreamController<List<int>>());

  final List<StreamController<List<int>>> controllers;
  var _request = 0;
  var closeCalls = 0;

  @override
  Future<StreamedResponse> send(BaseRequest request) async => StreamedResponse(controllers[_request++].stream, 200);

  @override
  void close() => closeCalls++;
}

final class _ResponseClient extends BaseClient {
  _ResponseClient(this.response);

  final StreamedResponse response;

  @override
  Future<StreamedResponse> send(BaseRequest request) async => response;
}

final class _StreamedResponseWithUrl extends StreamedResponse implements BaseResponseWithUrl {
  _StreamedResponseWithUrl(super.stream, super.statusCode, {required this.url});

  @override
  final Uri url;
}
