import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_probe_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';

void main() {
  group('EndpointProbeAdapter', () {
    test('resolves a same-origin well-known subpath and validates the cached user', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', body: '{"api":{"endpoint":"/immich/api"}}');
        session.respond('/immich/api/server/ping', body: '{"res":"pong"}');
        session.respond('/immich/api/users/me', body: '{"id":"user-1"}');
      });
      final adapter = EndpointProbeAdapter(
        transport: transport,
        commonHeaders: const {'x-request-id': 'request-1'},
        accessToken: 'token',
      );

      final result = await adapter.probe(_request()).result;

      expect(
        result,
        EndpointProbeResult.validated(
          canonicalOrigin: Uri.parse('https://photos.example.test'),
          apiEndpoint: Uri.parse('https://photos.example.test/immich/api'),
          userId: 'user-1',
          schemePolicy: EndpointSchemePolicy.httpsOnly,
        ),
      );
      expect(transport.sessions, hasLength(1));
      expect(transport.sessions.single.closed, isTrue);
      expect(transport.configurations.single.timeout, const Duration(seconds: 3));
      expect(transport.configurations.single.persistentCookiesEnabled, isFalse);
      expect(transport.configurations.single.cacheEnabled, isFalse);
      expect(transport.configurations.single.redirectPolicy, ProbeHttpRedirectPolicy.sameOriginOnly);
      expect(transport.sessions.single.requests[0].headers, {'x-request-id': 'request-1'});
      expect(transport.sessions.single.requests[1].headers, {'x-request-id': 'request-1'});
      expect(transport.sessions.single.requests[2].headers, {
        'x-request-id': 'request-1',
        'Authorization': 'Bearer token',
      });
    });

    test('preserves the candidate API subpath when well-known is absent', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', statusCode: 404);
        session.respond('/familia/api/server/ping', body: '{"res":"pong"}');
        session.respond('/familia/api/users/me', body: '{"id":"user-1"}');
      });
      final adapter = EndpointProbeAdapter(transport: transport);

      final result = await adapter
          .probe(_request(candidateApiEndpoint: Uri.parse('https://photos.example.test/familia/api')))
          .result;

      expect(
        (result as ValidatedEndpointProbeResult).apiEndpoint,
        Uri.parse('https://photos.example.test/familia/api'),
      );
    });

    test('rejects a well-known endpoint on another origin before pinging it', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', body: '{"api":{"endpoint":"https://attacker.example.test/api"}}');
      });
      final adapter = EndpointProbeAdapter(transport: transport);

      final result = await adapter.probe(_request()).result;

      expect(result, const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer));
      expect(transport.sessions.single.requests, hasLength(1));
    });

    test('rejects a cross-origin redirect reported by the isolated transport', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond(
          '/.well-known/immich',
          effectiveUri: Uri.parse('https://attacker.example.test/.well-known/immich'),
          redirectChain: [Uri.parse('https://attacker.example.test/.well-known/immich')],
        );
      });
      final adapter = EndpointProbeAdapter(transport: transport);

      final result = await adapter.probe(_request()).result;

      expect(result, const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer));
    });

    test('rejects another Immich user without touching authentication state', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', statusCode: 404);
        session.respond('/api/server/ping', body: '{"res":"pong"}');
        session.respond('/api/users/me', body: '{"id":"other-user"}');
      });
      final adapter = EndpointProbeAdapter(transport: transport);

      final result = await adapter.probe(_request()).result;

      expect(result, const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer));
    });

    test('maps an alternate endpoint 401 to unauthorized without invoking logout', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', statusCode: 404);
        session.respond('/api/server/ping', body: '{"res":"pong"}');
        session.respond('/api/users/me', statusCode: 401);
      });
      final adapter = EndpointProbeAdapter(transport: transport);

      final result = await adapter.probe(_request()).result;

      expect(result, const EndpointProbeResult.rejected(OfflineErrorCode.unauthorized));
    });

    test('rejects a server whose ping response is not Immich before sending credentials', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', statusCode: 404);
        session.respond('/api/server/ping', body: '{"res":"not-pong"}');
      });
      final adapter = EndpointProbeAdapter(transport: transport, accessToken: 'token');

      final result = await adapter.probe(_request()).result;

      expect(result, const EndpointProbeResult.rejected(OfflineErrorCode.wrongServer));
      expect(transport.sessions.single.requests, hasLength(2));
      expect(transport.sessions.single.requests.every((request) => !request.headers.containsKey('x-api-key')), isTrue);
    });

    test('strips credential, cookie and hop-by-hop headers from every probe request', () async {
      final transport = _FakeProbeHttpTransport((session) {
        session.respond('/.well-known/immich', statusCode: 404);
        session.respond('/api/server/ping', body: '{"res":"pong"}');
        session.respond('/api/users/me', body: '{"id":"user-1"}');
      });
      final adapter = EndpointProbeAdapter(
        transport: transport,
        accessToken: 'current-token',
        commonHeaders: const {
          'x-request-id': 'safe-correlation',
          'authorization': 'raw-authorization',
          'X-API-Key': 'raw-api-key',
          'Cookie': 'session=secret',
          'set-cookie': 'secret=response',
          'Proxy-Authorization': 'proxy-secret',
          'Connection': 'keep-alive',
          'Transfer-Encoding': 'chunked',
          'Upgrade': 'websocket',
        },
      );

      await adapter.probe(_request()).result;

      final requests = transport.sessions.single.requests;
      for (final request in requests) {
        expect(request.headers['x-request-id'], 'safe-correlation');
        final names = request.headers.keys.map((name) => name.toLowerCase()).toSet();
        for (final forbidden in <String>{
          'x-api-key',
          'cookie',
          'set-cookie',
          'proxy-authorization',
          'connection',
          'transfer-encoding',
          'upgrade',
        }) {
          expect(names, isNot(contains(forbidden)));
        }
      }
      expect(requests[0].headers.keys.map((name) => name.toLowerCase()), isNot(contains('authorization')));
      expect(requests[1].headers.keys.map((name) => name.toLowerCase()), isNot(contains('authorization')));
      expect(requests[2].headers['Authorization'], 'Bearer current-token');
    });

    test('times out with an injectable candidate deadline and cancels transport work', () async {
      final transport = _FakeProbeHttpTransport((_) {});
      final adapter = EndpointProbeAdapter(transport: transport, candidateTimeout: const Duration(milliseconds: 20));

      final operation = adapter.probe(_request());
      final result = await operation.result;

      expect(result, const EndpointProbeResult.rejected(OfflineErrorCode.timeout));
      expect(transport.sessions.single.operations.single.cancelled, isTrue);
      expect(transport.sessions.single.closed, isTrue);

      transport.sessions.single.operations.single.complete(
        ProbeHttpResponse(
          requestUri: Uri.parse('https://photos.example.test/.well-known/immich'),
          effectiveUri: Uri.parse('https://photos.example.test/.well-known/immich'),
          statusCode: 404,
        ),
      );
      expect(await operation.result, const EndpointProbeResult.rejected(OfflineErrorCode.timeout));
    });

    test('cancellation wins exactly once over a stale transport completion', () async {
      final transport = _FakeProbeHttpTransport((_) {});
      final operation = EndpointProbeAdapter(transport: transport).probe(_request());

      await operation.cancel();
      transport.sessions.single.operations.single.complete(
        ProbeHttpResponse(
          requestUri: Uri.parse('https://photos.example.test/.well-known/immich'),
          effectiveUri: Uri.parse('https://photos.example.test/.well-known/immich'),
          statusCode: 404,
        ),
      );

      expect(await operation.result, const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    });
  });
}

EndpointProbeRequest _request({Uri? candidateApiEndpoint}) => EndpointProbeRequest(
  candidateOrigin: Uri.parse('https://photos.example.test'),
  candidateApiEndpoint: candidateApiEndpoint ?? Uri.parse('https://photos.example.test/api'),
  expectedUserId: 'user-1',
  sessionEpoch: 3,
  probeGeneration: 7,
  schemePolicy: EndpointSchemePolicy.httpsOnly,
);

final class _FakeProbeHttpTransport implements ProbeHttpTransportPort {
  _FakeProbeHttpTransport(this.prepare);

  final void Function(_FakeProbeHttpSession session) prepare;
  final List<ProbeHttpSessionConfiguration> configurations = [];
  final List<_FakeProbeHttpSession> sessions = [];

  @override
  ProbeHttpSessionPort openEphemeralSession(ProbeHttpSessionConfiguration configuration) {
    configurations.add(configuration);
    final session = _FakeProbeHttpSession();
    sessions.add(session);
    prepare(session);
    return session;
  }
}

final class _FakeProbeHttpSession implements ProbeHttpSessionPort {
  final Map<String, ProbeHttpResponse> _responses = {};
  final List<ProbeHttpRequest> requests = [];
  final List<_ControlledRequest<ProbeHttpResponse>> operations = [];
  bool closed = false;

  void respond(
    String path, {
    int statusCode = 200,
    String body = '',
    Uri? effectiveUri,
    List<Uri> redirectChain = const [],
  }) {
    final requestUri = Uri.parse('https://photos.example.test$path');
    _responses[path] = ProbeHttpResponse(
      requestUri: requestUri,
      effectiveUri: effectiveUri ?? requestUri,
      statusCode: statusCode,
      body: body,
      redirectChain: redirectChain,
    );
  }

  @override
  CancellableRequest<ProbeHttpResponse> get(ProbeHttpRequest request) {
    requests.add(request);
    final operation = _ControlledRequest<ProbeHttpResponse>();
    operations.add(operation);
    final response = _responses[request.uri.path];
    if (response != null) {
      operation.complete(response);
    }
    return operation;
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _ControlledRequest<T> implements CancellableRequest<T> {
  final Completer<T> _completer = Completer<T>();
  bool cancelled = false;

  @override
  Future<T> get result => _completer.future;

  void complete(T value) {
    if (!_completer.isCompleted) {
      _completer.complete(value);
    }
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
  }
}
