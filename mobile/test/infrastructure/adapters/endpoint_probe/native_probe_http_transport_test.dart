import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/native_probe_http_transport.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';
import 'package:immich_mobile/platform/probe_http_api.g.dart';

void main() {
  group('NativeProbeHttpTransport', () {
    test('opens a bounded ephemeral session and maps a successful response', () async {
      final api = _FakeProbeHttpHostApi();
      final transport = NativeProbeHttpTransport(api: api);
      final session = transport.openEphemeralSession(_configuration());

      final operation = session.get(
        ProbeHttpRequest(
          uri: Uri.parse('https://photos.example.test/api/server/ping'),
          headers: const {'x-proxy-key': 'proxy'},
        ),
      );
      api.completeGet(
        NativeProbeHttpResult(
          response: NativeProbeHttpResponse(
            requestUrl: 'https://photos.example.test/api/server/ping',
            effectiveUrl: 'https://photos.example.test/base/api/server/ping',
            statusCode: 200,
            body: '{"res":"pong"}',
            redirectChain: ['https://photos.example.test/base/api/server/ping'],
          ),
        ),
      );

      final response = await operation.result;

      expect(api.openedSessions.single.timeoutMilliseconds, 3000);
      expect(api.requests.single.canonicalOrigin, 'https://photos.example.test');
      expect(api.requests.single.headers, {'x-proxy-key': 'proxy'});
      expect(response.statusCode, 200);
      expect(response.effectiveUri.path, '/base/api/server/ping');
      expect(response.redirectChain.single.path, '/base/api/server/ping');
    });

    test('rejects any request for persistent cache or cookies before calling native code', () {
      final api = _FakeProbeHttpHostApi();
      final transport = NativeProbeHttpTransport(api: api);

      expect(
        () => transport.openEphemeralSession(
          const ProbeHttpSessionConfiguration(
            timeout: Duration(seconds: 3),
            persistentCookiesEnabled: true,
            cacheEnabled: false,
            redirectPolicy: ProbeHttpRedirectPolicy.sameOriginOnly,
          ),
        ),
        throwsA(isA<ProbeHttpTransportException>()),
      );
      expect(api.openedSessions, isEmpty);
    });

    test('maps typed native failures without inventing an HTTP response', () async {
      final api = _FakeProbeHttpHostApi();
      final session = NativeProbeHttpTransport(api: api).openEphemeralSession(_configuration());
      final operation = session.get(ProbeHttpRequest(uri: Uri.parse('https://photos.example.test/api')));
      api.completeGet(NativeProbeHttpResult(error: NativeProbeHttpErrorCode.redirectRejected));

      await expectLater(
        operation.result,
        throwsA(
          isA<ProbeHttpTransportException>().having((error) => error.message, 'message', contains('redirectRejected')),
        ),
      );
    });

    test('cancel and close are idempotent and stale completion cannot win', () async {
      final api = _FakeProbeHttpHostApi();
      final session = NativeProbeHttpTransport(api: api).openEphemeralSession(_configuration());
      final operation = session.get(ProbeHttpRequest(uri: Uri.parse('https://photos.example.test/api')));
      final resultExpectation = expectLater(operation.result, throwsA(isA<ProbeHttpTransportException>()));

      await operation.cancel();
      await operation.cancel();
      api.completeGet(
        NativeProbeHttpResult(
          response: NativeProbeHttpResponse(
            requestUrl: 'https://photos.example.test/api',
            effectiveUrl: 'https://photos.example.test/api',
            statusCode: 200,
            body: 'late',
            redirectChain: const [],
          ),
        ),
      );
      await session.close();
      await session.close();

      await resultExpectation;
      expect(api.cancelledRequests, hasLength(1));
      expect(api.closedSessionIds, hasLength(1));
    });

    test('rejects malformed native response URLs at the platform boundary', () async {
      final api = _FakeProbeHttpHostApi();
      final session = NativeProbeHttpTransport(api: api).openEphemeralSession(_configuration());
      final operation = session.get(ProbeHttpRequest(uri: Uri.parse('https://photos.example.test/api')));
      api.completeGet(
        NativeProbeHttpResult(
          response: NativeProbeHttpResponse(
            requestUrl: 'not-a-url',
            effectiveUrl: 'https://photos.example.test/api',
            statusCode: 200,
            body: '',
            redirectChain: const [],
          ),
        ),
      );

      await expectLater(operation.result, throwsA(isA<ProbeHttpTransportException>()));
    });
  });
}

ProbeHttpSessionConfiguration _configuration() => const ProbeHttpSessionConfiguration(
  timeout: Duration(seconds: 3),
  persistentCookiesEnabled: false,
  cacheEnabled: false,
  redirectPolicy: ProbeHttpRedirectPolicy.sameOriginOnly,
);

final class _FakeProbeHttpHostApi implements ProbeHttpHostApi {
  final List<NativeProbeHttpSession> openedSessions = [];
  final List<NativeProbeHttpRequest> requests = [];
  final List<(int, int)> cancelledRequests = [];
  final List<int> closedSessionIds = [];
  final Completer<NativeProbeHttpResult> _getCompletion = Completer();

  @override
  Future<void> openSession(NativeProbeHttpSession session) async {
    openedSessions.add(session);
  }

  @override
  Future<NativeProbeHttpResult> get(NativeProbeHttpRequest request) {
    requests.add(request);
    return _getCompletion.future;
  }

  void completeGet(NativeProbeHttpResult result) {
    if (!_getCompletion.isCompleted) {
      _getCompletion.complete(result);
    }
  }

  @override
  Future<void> cancelRequest(int sessionId, int requestId) async {
    cancelledRequests.add((sessionId, requestId));
  }

  @override
  Future<void> closeSession(int sessionId) async {
    closedSessionIds.add(sessionId);
  }
}
