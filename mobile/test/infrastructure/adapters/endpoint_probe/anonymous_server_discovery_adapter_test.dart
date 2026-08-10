import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/anonymous_server_discovery.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/anonymous_server_discovery_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';

void main() {
  test('discovers and pings a server without sending credentials or requesting the current user', () async {
    final transport = _RecordingProbeTransport((session) {
      session.respond('/.well-known/immich', body: '{"api":{"endpoint":"/immich/api"}}');
      session.respond('/immich/api/server/ping', body: '{"res":"pong"}');
    });
    final adapter = AnonymousServerDiscoveryAdapter(transport: transport);

    final result = await adapter.discover('https://photos.example.test');

    expect(
      result,
      DiscoveredServerEndpoint(
        canonicalOrigin: Uri.parse('https://photos.example.test'),
        apiEndpoint: Uri.parse('https://photos.example.test/immich/api'),
      ),
    );
    final requests = transport.session.requests;
    expect(requests.map((request) => request.uri.path), ['/.well-known/immich', '/immich/api/server/ping']);
    expect(requests.every((request) => request.headers.isEmpty), isTrue);
    expect(requests.every((request) => request.uri.path != '/immich/api/users/me'), isTrue);
    expect(transport.configuration.persistentCookiesEnabled, isFalse);
    expect(transport.configuration.cacheEnabled, isFalse);
    expect(transport.configuration.redirectPolicy, ProbeHttpRedirectPolicy.sameOriginOnly);
    expect(transport.session.closed, isTrue);
  });

  test('uses the candidate API path when discovery is absent', () async {
    final transport = _RecordingProbeTransport((session) {
      session.respond('/.well-known/immich', statusCode: 404);
      session.respond('/family/api/server/ping', body: '{"res":"pong"}');
    });

    final result = await AnonymousServerDiscoveryAdapter(
      transport: transport,
    ).discover('https://photos.example.test/family');

    expect(result.apiEndpoint, Uri.parse('https://photos.example.test/family/api'));
  });
}

final class _RecordingProbeTransport implements ProbeHttpTransportPort {
  _RecordingProbeTransport(this.prepare);

  final void Function(_RecordingProbeSession session) prepare;
  late ProbeHttpSessionConfiguration configuration;
  late _RecordingProbeSession session;

  @override
  ProbeHttpSessionPort openEphemeralSession(ProbeHttpSessionConfiguration configuration) {
    this.configuration = configuration;
    session = _RecordingProbeSession();
    prepare(session);
    return session;
  }
}

final class _RecordingProbeSession implements ProbeHttpSessionPort {
  final Map<String, ProbeHttpResponse> _responses = {};
  final List<ProbeHttpRequest> requests = [];
  bool closed = false;

  void respond(String path, {int statusCode = 200, String body = ''}) {
    final uri = Uri.parse('https://photos.example.test$path');
    _responses[path] = ProbeHttpResponse(requestUri: uri, effectiveUri: uri, statusCode: statusCode, body: body);
  }

  @override
  CancellableRequest<ProbeHttpResponse> get(ProbeHttpRequest request) {
    requests.add(request);
    return _CompletedRequest(_responses[request.uri.path]!);
  }

  @override
  Future<void> close() async {
    closed = true;
  }
}

final class _CompletedRequest<T> implements CancellableRequest<T> {
  _CompletedRequest(this.value);

  final T value;

  @override
  Future<T> get result async => value;

  @override
  Future<void> cancel() async {}
}
