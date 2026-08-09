import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_activation.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe_cycle.interface.dart';
import 'package:immich_mobile/domain/interfaces/reachability_scheduler.interface.dart';
import 'package:immich_mobile/domain/interfaces/reachability_state_publisher.interface.dart';
import 'package:immich_mobile/domain/interfaces/reconciliation.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';

final class ServerReachabilityCoordinator {
  ServerReachabilityCoordinator({
    required SessionEpochController epochs,
    required ConnectivityMonitorPort connectivity,
    required EndpointProbeCyclePort probeCycles,
    required EndpointActivationPort activations,
    required ReconciliationPort reconciliations,
    required ReachabilityStatePublisherPort statePublisher,
    required ReachabilitySchedulerPort scheduler,
    this.debounce = const Duration(milliseconds: 750),
  }) : _epochs = epochs,
       _connectivity = connectivity,
       _probeCycles = probeCycles,
       _activations = activations,
       _reconciliations = reconciliations,
       _statePublisher = statePublisher,
       _scheduler = scheduler,
       _state = ReachabilityState(
         phase: ReachabilityPhase.unknown,
         sessionEpoch: epochs.current.sessionEpoch,
         probeGeneration: epochs.current.probeGeneration,
       ) {
    if (debounce.isNegative) {
      throw ArgumentError.value(debounce, 'debounce', 'Must not be negative');
    }
  }

  final SessionEpochController _epochs;
  final ConnectivityMonitorPort _connectivity;
  final EndpointProbeCyclePort _probeCycles;
  final EndpointActivationPort _activations;
  final ReconciliationPort _reconciliations;
  final ReachabilityStatePublisherPort _statePublisher;
  final ReachabilitySchedulerPort _scheduler;
  final Duration debounce;

  ReachabilityState _state;
  ReachabilityState get state => _state;

  StreamSubscription<TransportAvailability>? _connectivitySubscription;
  ScheduledReachabilityTask? _scheduledCycle;
  _PipelineRun? _pipeline;
  Future<void>? _startFuture;
  Future<void>? _disposeFuture;
  Future<void>? _pauseFuture;
  TransportAvailability _availability = TransportAvailability.unknown;
  int _availabilityRevision = 0;
  bool _sessionActive = false;
  bool _paused = false;
  bool _disposed = false;
  bool _rerunRequested = false;

  Future<void> start() {
    if (_disposed) {
      return Future.value();
    }
    return _startFuture ??= _start();
  }

  void activateSession({Uri? confirmedEndpoint}) {
    _ensureNotDisposed();
    _sessionActive = true;
    _publish(
      _paused ? ReachabilityPhase.paused : _phaseForAvailability(),
      identity: _epochs.current,
      confirmedEndpoint: confirmedEndpoint,
    );
    if (!_paused && _availability == TransportAvailability.available) {
      _scheduleCycle();
    }
  }

  Future<void> pause() {
    if (_disposed) {
      return Future.value();
    }
    final pendingPause = _pauseFuture;
    if (_paused && pendingPause != null) {
      return pendingPause;
    }
    if (_paused) {
      return Future.value();
    }
    _paused = true;
    _epochs.invalidateProbeGeneration();
    _cancelScheduledCycle();
    _rerunRequested = false;
    _publish(ReachabilityPhase.paused, identity: _epochs.current, confirmedEndpoint: _state.confirmedEndpoint);
    return _pauseFuture = _cancelPipelineAndWait();
  }

  void resume() {
    if (_disposed || !_paused) {
      return;
    }
    _paused = false;
    _pauseFuture = null;
    if (!_sessionActive) {
      return;
    }
    _publish(_phaseForAvailability(), identity: _epochs.current, confirmedEndpoint: _state.confirmedEndpoint);
    if (_availability == TransportAvailability.available) {
      _scheduleCycle();
    }
  }

  Future<void> logout() async {
    if (_disposed) {
      return;
    }
    _sessionActive = false;
    _paused = false;
    _epochs.invalidateSession();
    _cancelScheduledCycle();
    _rerunRequested = false;
    _publish(ReachabilityPhase.offline, identity: _epochs.current, confirmedEndpoint: null);
    await _cancelPipelineAndWait();
  }

  Future<void> dispose() {
    final existing = _disposeFuture;
    if (existing != null) {
      return existing;
    }
    _disposed = true;
    _sessionActive = false;
    _paused = false;
    _epochs.invalidateProbeGeneration();
    _cancelScheduledCycle();
    _rerunRequested = false;
    _publish(ReachabilityPhase.disposed, identity: _epochs.current, confirmedEndpoint: null);
    return _disposeFuture = _releaseResources();
  }

  Future<void> _start() async {
    final revisionBeforeInitialAvailability = _availabilityRevision;
    _connectivitySubscription = _connectivity.events.listen(_handleAvailability);
    _statePublisher.publish(_state);
    final initialAvailability = await _connectivity.initialAvailability;
    if (_disposed || revisionBeforeInitialAvailability != _availabilityRevision) {
      return;
    }
    _handleAvailability(initialAvailability);
  }

  void _handleAvailability(TransportAvailability availability) {
    if (_disposed) {
      return;
    }
    _availabilityRevision++;
    if (_availability == availability) {
      return;
    }
    _availability = availability;
    switch (availability) {
      case TransportAvailability.unknown:
        return;
      case TransportAvailability.unavailable:
        _handleUnavailable();
      case TransportAvailability.available:
        _handleAvailable();
    }
  }

  void _handleUnavailable() {
    _epochs.invalidateProbeGeneration();
    _cancelScheduledCycle();
    _rerunRequested = false;
    if (_sessionActive && !_paused) {
      _publish(ReachabilityPhase.offline, identity: _epochs.current, confirmedEndpoint: _state.confirmedEndpoint);
    }
    unawaited(_cancelPipelineAndWait());
  }

  void _handleAvailable() {
    if (!_sessionActive || _paused) {
      return;
    }
    _scheduleCycle();
  }

  void _scheduleCycle() {
    if (!_canRunCycle) {
      return;
    }
    if (_pipeline != null) {
      _rerunRequested = true;
      return;
    }
    _cancelScheduledCycle();
    _scheduledCycle = _scheduler.schedule(debounce, _beginCycle);
  }

  void _beginCycle() {
    _scheduledCycle = null;
    if (!_canRunCycle || _pipeline != null) {
      return;
    }
    final identity = _epochs.beginProbeCycle();
    _publish(ReachabilityPhase.probing, identity: identity, confirmedEndpoint: _state.confirmedEndpoint);
    final run = _PipelineRun(identity);
    _pipeline = run;
    run.future = _executePipeline(run);
  }

  Future<void> _executePipeline(_PipelineRun run) async {
    try {
      await _executePipelineStages(run);
    } finally {
      _finishPipeline(run);
    }
  }

  Future<void> _executePipelineStages(_PipelineRun run) async {
    late final EndpointProbeResult probeResult;
    try {
      probeResult = await _runProbe(run);
    } on Object {
      _publishOfflineIfCurrent(run.identity);
      return;
    }
    if (!_isCurrent(run.identity) || probeResult is! ValidatedEndpointProbeResult) {
      if (_isCurrent(run.identity) && probeResult is RejectedEndpointProbeResult) {
        _publishProbeFailure(probeResult, run.identity);
      }
      return;
    }

    late final OfflineResult<EndpointActivationReceipt> activationResult;
    try {
      activationResult = await _runActivation(run, probeResult);
    } on Object {
      _publishOfflineIfCurrent(run.identity);
      return;
    }
    if (!_isCurrent(run.identity)) {
      return;
    }
    final receipt = activationResult.valueOrNull;
    if (receipt == null) {
      _publishEffectFailure(activationResult.errorOrNull, run.identity);
      return;
    }
    if (!_matches(receipt, run.identity)) {
      return;
    }

    _publish(ReachabilityPhase.online, identity: run.identity, confirmedEndpoint: receipt.confirmedEndpoint);
    try {
      await _runReconciliation(run, receipt);
    } on Object {
      return;
    }
  }

  Future<EndpointProbeResult> _runProbe(_PipelineRun run) {
    final operation = _probeCycles.begin(run.identity);
    run.operation = operation;
    return operation.result;
  }

  Future<OfflineResult<EndpointActivationReceipt>> _runActivation(
    _PipelineRun run,
    ValidatedEndpointProbeResult endpoint,
  ) {
    final operation = _activations.activate(
      EndpointActivationRequest(
        endpoint: endpoint,
        sessionEpoch: run.identity.sessionEpoch,
        probeGeneration: run.identity.probeGeneration,
      ),
    );
    run.operation = operation;
    return operation.result;
  }

  Future<OfflineResult<OperationCompletion>> _runReconciliation(_PipelineRun run, EndpointActivationReceipt receipt) {
    final operation = _reconciliations.reconcile(
      ReconciliationRequest(
        sessionEpoch: receipt.sessionEpoch,
        probeGeneration: receipt.probeGeneration,
        confirmedEndpoint: receipt.confirmedEndpoint,
      ),
    );
    run.operation = operation;
    return operation.result;
  }

  void _publishProbeFailure(RejectedEndpointProbeResult result, ReachabilityIdentity identity) {
    if (result.error == OfflineErrorCode.cancelled) {
      return;
    }
    _publish(ReachabilityPhase.offline, identity: identity, confirmedEndpoint: _state.confirmedEndpoint);
  }

  void _publishEffectFailure(OfflineErrorCode? error, ReachabilityIdentity identity) {
    if (error == null || error == OfflineErrorCode.cancelled) {
      return;
    }
    _publish(ReachabilityPhase.offline, identity: identity, confirmedEndpoint: _state.confirmedEndpoint);
  }

  void _publishOfflineIfCurrent(ReachabilityIdentity identity) {
    if (_isCurrent(identity)) {
      _publish(ReachabilityPhase.offline, identity: identity, confirmedEndpoint: _state.confirmedEndpoint);
    }
  }

  void _finishPipeline(_PipelineRun run) {
    if (!identical(_pipeline, run)) {
      return;
    }
    _pipeline = null;
    run.operation = null;
    final rerun = _rerunRequested;
    _rerunRequested = false;
    if (rerun && _canRunCycle) {
      _scheduleCycle();
    }
  }

  Future<void> _cancelPipelineAndWait() {
    final run = _pipeline;
    if (run == null) {
      return Future.value();
    }
    return run.cancellation ??= _cancelRun(run);
  }

  Future<void> _cancelRun(_PipelineRun run) async {
    Object? firstError;
    StackTrace? firstStackTrace;
    try {
      await run.operation?.cancel();
    } on Object catch (error, stackTrace) {
      firstError = error;
      firstStackTrace = stackTrace;
    }
    try {
      await run.future;
    } on Object catch (error, stackTrace) {
      firstError ??= error;
      firstStackTrace ??= stackTrace;
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError, firstStackTrace!);
    }
  }

  Future<void> _releaseResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(Future<void> Function() release) async {
      try {
        await release();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(_cancelPipelineAndWait);
    final subscription = _connectivitySubscription;
    _connectivitySubscription = null;
    await attempt(() async {
      await subscription?.cancel();
    });
    await attempt(_connectivity.dispose);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void _cancelScheduledCycle() {
    _scheduledCycle?.cancel();
    _scheduledCycle = null;
  }

  ReachabilityPhase _phaseForAvailability() {
    return switch (_availability) {
      TransportAvailability.unknown => ReachabilityPhase.unknown,
      TransportAvailability.unavailable => ReachabilityPhase.offline,
      TransportAvailability.available => ReachabilityPhase.unknown,
    };
  }

  bool get _canRunCycle {
    return !_disposed && _sessionActive && !_paused && _availability == TransportAvailability.available;
  }

  bool _isCurrent(ReachabilityIdentity identity) => _canRunCycle && _epochs.isCurrent(identity);

  bool _matches(EndpointActivationReceipt receipt, ReachabilityIdentity identity) {
    return receipt.sessionEpoch == identity.sessionEpoch && receipt.probeGeneration == identity.probeGeneration;
  }

  void _publish(ReachabilityPhase phase, {required ReachabilityIdentity identity, required Uri? confirmedEndpoint}) {
    _state = ReachabilityState(
      phase: phase,
      sessionEpoch: identity.sessionEpoch,
      probeGeneration: identity.probeGeneration,
      confirmedEndpoint: confirmedEndpoint,
    );
    _statePublisher.publish(_state);
  }

  void _ensureNotDisposed() {
    if (_disposed) {
      throw StateError('ServerReachabilityCoordinator is disposed');
    }
  }
}

final class _PipelineRun {
  _PipelineRun(this.identity);

  final ReachabilityIdentity identity;
  late final Future<void> future;
  CancellableRequest<Object?>? operation;
  Future<void>? cancellation;
}
