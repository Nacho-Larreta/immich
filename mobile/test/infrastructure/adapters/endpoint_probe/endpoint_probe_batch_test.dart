import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/endpoint_probe_batch.dart';

void main() {
  group('EndpointProbeBatch', () {
    test('rejects concurrency limits outside the absolute range of one to two', () {
      final port = _ControlledEndpointProbePort();

      expect(() => EndpointProbeBatch(port: port, maximumConcurrentProbes: 0), throwsArgumentError);
      expect(() => EndpointProbeBatch(port: port, maximumConcurrentProbes: 3), throwsArgumentError);
      expect(port.startedOrigins, isEmpty);
    });

    test('rejects an empty batch before starting transport', () {
      final port = _ControlledEndpointProbePort();

      expect(() => EndpointProbeBatch(port: port).probeCandidates(const []), throwsArgumentError);
      expect(port.startedOrigins, isEmpty);
    });

    test('runs at most two probes and starts queued candidates in order', () async {
      final port = _ControlledEndpointProbePort();
      final batch = EndpointProbeBatch(port: port);
      final operation = batch.probeCandidates(_requests(4));

      expect(port.startedOrigins, ['https://candidate-0.test', 'https://candidate-1.test']);
      expect(port.maxActive, 2);

      port.reject(0, OfflineErrorCode.serverUnavailable);
      await Future<void>.delayed(Duration.zero);

      expect(port.startedOrigins, ['https://candidate-0.test', 'https://candidate-1.test', 'https://candidate-2.test']);
      expect(port.maxActive, 2);

      port.reject(1, OfflineErrorCode.serverUnavailable);
      port.reject(2, OfflineErrorCode.serverUnavailable);
      await Future<void>.delayed(Duration.zero);
      port.reject(3, OfflineErrorCode.serverUnavailable);

      expect(await operation.result, const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable));
      expect(port.maxActive, 2);
    });

    test('a faster lower-priority success waits for preceding candidates', () async {
      final port = _ControlledEndpointProbePort();
      final operation = EndpointProbeBatch(port: port).probeCandidates(_requests(3));
      var completed = false;
      unawaited(operation.result.then((_) => completed = true));

      port.validate(1);
      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      port.reject(0, OfflineErrorCode.timeout);

      expect(await operation.result, isA<ValidatedEndpointProbeResult>());
      expect((await operation.result as ValidatedEndpointProbeResult).canonicalOrigin.host, 'candidate-1.test');
      expect(port.operations[2].cancelled, isTrue);
    });

    test('cancellation rejects the batch and ignores stale completions', () async {
      final port = _ControlledEndpointProbePort();
      final operation = EndpointProbeBatch(port: port).probeCandidates(_requests(3));

      await operation.cancel();
      port.validate(0);
      port.validate(1);

      expect(await operation.result, const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
      expect(port.operations.take(2).every((probe) => probe.cancelled), isTrue);
      expect(port.startedOrigins, hasLength(2));
    });

    test('rejects mixed epoch, generation, or user metadata before starting transport', () {
      final requests = _requests(2);
      final incompatibleRequests = [
        _replaceRequest(requests[1], sessionEpoch: 99),
        _replaceRequest(requests[1], probeGeneration: 99),
        _replaceRequest(requests[1], expectedUserId: 'other-user'),
      ];

      for (final incompatibleRequest in incompatibleRequests) {
        final port = _ControlledEndpointProbePort();
        expect(
          () => EndpointProbeBatch(port: port).probeCandidates([requests.first, incompatibleRequest]),
          throwsArgumentError,
        );
        expect(port.startedOrigins, isEmpty);
      }
    });
  });
}

List<EndpointProbeRequest> _requests(int count) => List.generate(
  count,
  (index) => EndpointProbeRequest(
    candidateOrigin: Uri.parse('https://candidate-$index.test'),
    candidateApiEndpoint: Uri.parse('https://candidate-$index.test/family/api'),
    expectedUserId: 'user-1',
    sessionEpoch: 2,
    probeGeneration: 5,
    schemePolicy: EndpointSchemePolicy.httpsOnly,
  ),
);

EndpointProbeRequest _replaceRequest(
  EndpointProbeRequest request, {
  int? sessionEpoch,
  int? probeGeneration,
  String? expectedUserId,
}) => EndpointProbeRequest(
  candidateOrigin: request.candidateOrigin,
  candidateApiEndpoint: request.candidateApiEndpoint,
  expectedUserId: expectedUserId ?? request.expectedUserId,
  sessionEpoch: sessionEpoch ?? request.sessionEpoch,
  probeGeneration: probeGeneration ?? request.probeGeneration,
  schemePolicy: request.schemePolicy,
);

final class _ControlledEndpointProbePort implements EndpointProbePort {
  final List<String> startedOrigins = [];
  final List<_ControlledProbe> operations = [];
  int active = 0;
  int maxActive = 0;

  @override
  CancellableRequest<EndpointProbeResult> probe(EndpointProbeRequest request) {
    startedOrigins.add(request.candidateOrigin.toString());
    active++;
    if (active > maxActive) {
      maxActive = active;
    }
    final operation = _ControlledProbe(request, () => active--);
    operations.add(operation);
    return operation;
  }

  void reject(int index, OfflineErrorCode error) {
    operations[index].complete(EndpointProbeResult.rejected(error));
  }

  void validate(int index) {
    final request = operations[index].request;
    operations[index].complete(
      EndpointProbeResult.validated(
        canonicalOrigin: request.candidateOrigin,
        apiEndpoint: request.candidateApiEndpoint,
        userId: request.expectedUserId,
        schemePolicy: request.schemePolicy,
      ),
    );
  }
}

final class _ControlledProbe implements CancellableRequest<EndpointProbeResult> {
  _ControlledProbe(this.request, this.onSettled);

  final EndpointProbeRequest request;
  final void Function() onSettled;
  final Completer<EndpointProbeResult> _completer = Completer<EndpointProbeResult>();
  bool cancelled = false;
  bool _settled = false;

  @override
  Future<EndpointProbeResult> get result => _completer.future;

  void complete(EndpointProbeResult result) {
    if (_completer.isCompleted) {
      return;
    }
    _completer.complete(result);
    _settle();
  }

  @override
  Future<void> cancel() async {
    cancelled = true;
    _settle();
  }

  void _settle() {
    if (_settled) {
      return;
    }
    _settled = true;
    onSettled();
  }
}
