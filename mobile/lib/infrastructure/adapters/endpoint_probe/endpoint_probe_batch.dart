import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

final class EndpointProbeBatch {
  EndpointProbeBatch({required this.port, this.maximumConcurrentProbes = 2}) {
    if (maximumConcurrentProbes < 1 || maximumConcurrentProbes > 2) {
      throw ArgumentError.value(maximumConcurrentProbes, 'maximumConcurrentProbes', 'Must be between one and two');
    }
  }

  final EndpointProbePort port;
  final int maximumConcurrentProbes;

  CancellableRequest<EndpointProbeResult> probeCandidates(Iterable<EndpointProbeRequest> requests) {
    final candidates = requests.toList(growable: false);
    _validateBatch(candidates);
    final operation = _EndpointProbeBatchOperation(
      port: port,
      candidates: candidates,
      maximumConcurrentProbes: maximumConcurrentProbes,
    );
    operation.start();
    return operation;
  }
}

void _validateBatch(List<EndpointProbeRequest> candidates) {
  if (candidates.isEmpty) {
    throw ArgumentError.value(candidates, 'requests', 'Must not be empty');
  }
  final first = candidates.first;
  final hasMixedMetadata = candidates
      .skip(1)
      .any(
        (candidate) =>
            candidate.sessionEpoch != first.sessionEpoch ||
            candidate.probeGeneration != first.probeGeneration ||
            candidate.expectedUserId != first.expectedUserId,
      );
  if (hasMixedMetadata) {
    throw ArgumentError.value(candidates, 'requests', 'Must share epoch, generation, and expected user');
  }
}

final class _EndpointProbeBatchOperation implements CancellableRequest<EndpointProbeResult> {
  _EndpointProbeBatchOperation({required this.port, required this.candidates, required this.maximumConcurrentProbes})
    : _results = List.filled(candidates.length, null);

  final EndpointProbePort port;
  final List<EndpointProbeRequest> candidates;
  final int maximumConcurrentProbes;
  final List<EndpointProbeResult?> _results;
  final Map<int, CancellableRequest<EndpointProbeResult>> _activeOperations = {};
  final Completer<EndpointProbeResult> _completion = Completer();

  int _nextCandidate = 0;
  int _nextPriority = 0;
  OfflineErrorCode? _highestPriorityFailure;
  bool _settled = false;

  @override
  Future<EndpointProbeResult> get result => _completion.future;

  void start() {
    _fillAvailableSlots();
  }

  void _fillAvailableSlots() {
    while (!_settled && _activeOperations.length < maximumConcurrentProbes && _nextCandidate < candidates.length) {
      final candidateIndex = _nextCandidate++;
      final operation = port.probe(candidates[candidateIndex]);
      _activeOperations[candidateIndex] = operation;
      unawaited(_observe(candidateIndex, operation));
    }
  }

  Future<void> _observe(int candidateIndex, CancellableRequest<EndpointProbeResult> operation) async {
    final probeResult = await operation.result;
    if (_settled || !_activeOperations.containsKey(candidateIndex)) {
      return;
    }
    _activeOperations.remove(candidateIndex);
    _results[candidateIndex] = probeResult;

    final winner = _resolveCompletedPriorities();
    if (winner != null) {
      await _finish(winner);
      return;
    }
    if (_nextPriority == candidates.length) {
      await _finish(EndpointProbeResult.rejected(_highestPriorityFailure ?? OfflineErrorCode.serverUnavailable));
      return;
    }
    _fillAvailableSlots();
  }

  ValidatedEndpointProbeResult? _resolveCompletedPriorities() {
    while (_nextPriority < _results.length) {
      final result = _results[_nextPriority];
      if (result == null) {
        return null;
      }
      if (result is ValidatedEndpointProbeResult) {
        return result;
      }
      _highestPriorityFailure ??= (result as RejectedEndpointProbeResult).error;
      _nextPriority++;
    }
    return null;
  }

  @override
  Future<void> cancel() {
    return _finish(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
  }

  Future<void> _finish(EndpointProbeResult batchResult) async {
    if (_settled) {
      return;
    }
    _settled = true;
    final operations = _activeOperations.values.toList(growable: false);
    _activeOperations.clear();
    await Future.wait(operations.map((operation) => operation.cancel()));
    _completion.complete(batchResult);
  }
}
