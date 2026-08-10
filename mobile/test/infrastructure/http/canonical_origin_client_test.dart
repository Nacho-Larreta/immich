import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart';
import 'package:http/testing.dart';
import 'package:immich_mobile/infrastructure/http/canonical_origin_client.dart';

void main() {
  test('allows requests with the exact scheme host and effective port', () async {
    late Uri sentUri;
    final client = CanonicalOriginClient(
      MockClient((request) async {
        sentUri = request.url;
        return Response('', 200);
      }),
      () => RequestOriginContext.restricted([Uri.parse('https://photos.test')]),
    );

    await client.get(Uri.parse('https://PHOTOS.test:443/family/api/assets'));

    expect(sentUri.path, '/family/api/assets');
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
