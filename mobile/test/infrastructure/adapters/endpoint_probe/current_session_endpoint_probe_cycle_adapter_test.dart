import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/current_session_endpoint_probe_cycle_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';

void main() {
  test('cancel during WiFi-backed snapshot prevents every HTTP probe', () async {
    final snapshot = Completer<EndpointProbeCycleSnapshot>();
    final transport = _ProbeTransport();
    final operation = CurrentSessionEndpointProbeCycleAdapter(
      readSnapshot: () => snapshot.future,
      transport: transport,
    ).begin(ReachabilityIdentity(sessionEpoch: 1, probeGeneration: 2));

    await operation.cancel();
    snapshot.complete(_snapshot(token: 'late-token'));
    await pumpEventQueue();

    expect(await operation.result, const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    expect(transport.sessions, isEmpty);
  });

  test('reads fresh credentials and headers for every login cycle', () async {
    var token = 'first-token';
    var requestId = 'first-request';
    final transport = _ProbeTransport();
    final adapter = CurrentSessionEndpointProbeCycleAdapter(
      readSnapshot: () async => _snapshot(token: token, requestId: requestId),
      transport: transport,
    );

    await adapter.begin(ReachabilityIdentity(sessionEpoch: 1, probeGeneration: 1)).result;
    token = 'second-token';
    requestId = 'second-request';
    await adapter.begin(ReachabilityIdentity(sessionEpoch: 2, probeGeneration: 1)).result;

    expect(transport.sessions[0].requests.last.headers, {
      'x-request-id': 'first-request',
      'Authorization': 'Bearer first-token',
    });
    expect(transport.sessions[1].requests.last.headers, {
      'x-request-id': 'second-request',
      'Authorization': 'Bearer second-token',
    });
  });

  test('maps a snapshot without approved candidates to server unavailable', () async {
    final transport = _ProbeTransport();
    final adapter = CurrentSessionEndpointProbeCycleAdapter(
      readSnapshot: () async => EndpointProbeCycleSnapshot(
        currentEndpoint: null,
        currentEndpointPolicy: null,
        externalEndpoints: const [],
        registeredLocalEndpoint: null,
        currentWifiName: null,
        preferredWifiName: null,
        expectedUserId: 'user-1',
        accessToken: 'token',
        customHeaders: const {},
      ),
      transport: transport,
    );

    expect(
      await adapter.begin(ReachabilityIdentity(sessionEpoch: 1, probeGeneration: 1)).result,
      const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable),
    );
    expect(transport.sessions, isEmpty);
  });
}

EndpointProbeCycleSnapshot _snapshot({required String token, String requestId = 'request'}) {
  return EndpointProbeCycleSnapshot(
    currentEndpoint: 'https://photos.example.test/api',
    currentEndpointPolicy: EndpointSchemePolicy.httpsOnly,
    externalEndpoints: const [],
    registeredLocalEndpoint: null,
    currentWifiName: null,
    preferredWifiName: null,
    expectedUserId: 'user-1',
    accessToken: token,
    customHeaders: {'x-request-id': requestId},
  );
}

final class _ProbeTransport implements ProbeHttpTransportPort {
  final sessions = <_ProbeSession>[];

  @override
  ProbeHttpSessionPort openEphemeralSession(ProbeHttpSessionConfiguration configuration) {
    final session = _ProbeSession();
    sessions.add(session);
    return session;
  }
}

final class _ProbeSession implements ProbeHttpSessionPort {
  final requests = <ProbeHttpRequest>[];

  @override
  CancellableRequest<ProbeHttpResponse> get(ProbeHttpRequest request) {
    requests.add(request);
    final response = switch (request.uri.path) {
      '/.well-known/immich' => _response(request.uri, statusCode: 404),
      '/api/server/ping' => _response(request.uri, body: '{"res":"pong"}'),
      '/api/users/me' => _response(request.uri, body: '{"id":"user-1"}'),
      _ => _response(request.uri, statusCode: 404),
    };
    return _ImmediateRequest(response);
  }

  @override
  Future<void> close() async {}
}

ProbeHttpResponse _response(Uri uri, {int statusCode = 200, String body = ''}) {
  return ProbeHttpResponse(requestUri: uri, effectiveUri: uri, statusCode: statusCode, body: body);
}

final class _ImmediateRequest<T> implements CancellableRequest<T> {
  const _ImmediateRequest(this.value);

  final T value;

  @override
  Future<T> get result => Future.value(value);

  @override
  Future<void> cancel() async {}
}
