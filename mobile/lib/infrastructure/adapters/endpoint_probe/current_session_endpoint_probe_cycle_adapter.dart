import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe_cycle.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_candidate_builder.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_probe_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_probe_batch.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';

typedef EndpointProbeCycleSnapshotReader = Future<EndpointProbeCycleSnapshot> Function();

final class EndpointProbeCycleSnapshot {
  EndpointProbeCycleSnapshot({
    required this.currentEndpoint,
    required this.currentEndpointPolicy,
    required Iterable<String> externalEndpoints,
    required this.registeredLocalEndpoint,
    required this.currentWifiName,
    required this.preferredWifiName,
    required this.expectedUserId,
    required this.accessToken,
    required Map<String, String> customHeaders,
  }) : externalEndpoints = List.unmodifiable(externalEndpoints),
       customHeaders = Map.unmodifiable(customHeaders);

  final String? currentEndpoint;
  final EndpointSchemePolicy? currentEndpointPolicy;
  final List<String> externalEndpoints;
  final String? registeredLocalEndpoint;
  final String? currentWifiName;
  final String? preferredWifiName;
  final String expectedUserId;
  final String accessToken;
  final Map<String, String> customHeaders;
}

final class CurrentSessionEndpointProbeCycleAdapter implements EndpointProbeCyclePort {
  const CurrentSessionEndpointProbeCycleAdapter({
    required EndpointProbeCycleSnapshotReader readSnapshot,
    required ProbeHttpTransportPort transport,
    EndpointCandidateBuilder candidateBuilder = const EndpointCandidateBuilder(),
  }) : _readSnapshot = readSnapshot,
       _transport = transport,
       _candidateBuilder = candidateBuilder;

  final EndpointProbeCycleSnapshotReader _readSnapshot;
  final ProbeHttpTransportPort _transport;
  final EndpointCandidateBuilder _candidateBuilder;

  @override
  CancellableRequest<EndpointProbeResult> begin(ReachabilityIdentity identity) {
    final operation = _CurrentSessionEndpointProbeCycleOperation(
      identity: identity,
      readSnapshot: _readSnapshot,
      transport: _transport,
      candidateBuilder: _candidateBuilder,
    );
    operation.start();
    return operation;
  }
}

final class _CurrentSessionEndpointProbeCycleOperation implements CancellableRequest<EndpointProbeResult> {
  _CurrentSessionEndpointProbeCycleOperation({
    required this.identity,
    required this.readSnapshot,
    required this.transport,
    required this.candidateBuilder,
  });

  final ReachabilityIdentity identity;
  final EndpointProbeCycleSnapshotReader readSnapshot;
  final ProbeHttpTransportPort transport;
  final EndpointCandidateBuilder candidateBuilder;
  final Completer<EndpointProbeResult> _completion = Completer();

  CancellableRequest<EndpointProbeResult>? _batch;
  bool _cancelled = false;

  @override
  Future<EndpointProbeResult> get result => _completion.future;

  void start() => unawaited(_run());

  Future<void> _run() async {
    try {
      final snapshot = await readSnapshot();
      if (_cancelled) {
        return;
      }
      if (snapshot.expectedUserId.isEmpty || snapshot.accessToken.isEmpty) {
        _complete(const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable));
        return;
      }
      final candidates = candidateBuilder.build(
        currentEndpoint: snapshot.currentEndpoint,
        currentEndpointPolicy: snapshot.currentEndpointPolicy,
        externalEndpoints: snapshot.externalEndpoints,
        registeredLocalEndpoint: snapshot.registeredLocalEndpoint,
        currentWifiName: snapshot.currentWifiName,
        preferredWifiName: snapshot.preferredWifiName,
        expectedUserId: snapshot.expectedUserId,
        sessionEpoch: identity.sessionEpoch,
        probeGeneration: identity.probeGeneration,
      );
      if (candidates.isEmpty) {
        _complete(const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable));
        return;
      }
      final probe = EndpointProbeAdapter(
        transport: transport,
        commonHeaders: snapshot.customHeaders,
        accessToken: snapshot.accessToken,
      );
      final batch = EndpointProbeBatch(port: probe).probeCandidates(candidates);
      _batch = batch;
      final probeResult = await batch.result;
      if (!_cancelled) {
        _complete(probeResult);
      }
    } on Object {
      if (!_cancelled) {
        _complete(const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable));
      }
    }
  }

  @override
  Future<void> cancel() async {
    if (_cancelled) {
      return;
    }
    _cancelled = true;
    await _batch?.cancel();
    _complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
  }

  void _complete(EndpointProbeResult result) {
    if (!_completion.isCompleted) {
      _completion.complete(result);
    }
  }
}
