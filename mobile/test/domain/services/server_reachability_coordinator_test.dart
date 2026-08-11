import 'dart:async';
import 'dart:collection';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/confirmed_server_access.interface.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_activation.interface.dart';
import 'package:immich_mobile/domain/interfaces/endpoint_probe_cycle.interface.dart';
import 'package:immich_mobile/domain/interfaces/reachability_state_publisher.interface.dart';
import 'package:immich_mobile/domain/interfaces/reachability_failure_reporter.interface.dart';
import 'package:immich_mobile/domain/interfaces/reconciliation.interface.dart';
import 'package:immich_mobile/domain/interfaces/request_context_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/server_reachability_coordinator.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';

import 'support/manual_reachability_scheduler.dart';

void main() {
  test('rehydrated HTTPS proof flows through coordinator into a generation-bound media request', () async {
    final connectivity = _ConnectivityMonitor(initialAvailability: Future.value(TransportAvailability.available));
    final harness = _Harness(connectivity: connectivity);
    final probe = harness.probes.enqueuePending();

    await harness.startSession();
    final access = mapRemoteMediaAccess(harness.coordinator.state);
    final request = RemoteMediaRequest(
      requestId: 1,
      resource: Uri.parse('https://cached.example.test/api/assets/1/thumbnail'),
      policy: access.policy,
      kind: MediaRequestKind.thumbnail,
      preferEncoded: false,
      expectedContextGeneration: access.expectedContextGeneration,
    );

    expect(harness.coordinator.state.phase, ReachabilityPhase.probing);
    expect(request.policy, RemoteMediaPolicy.cacheThenNetwork);
    expect(request.expectedContextGeneration, 11);
    probe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await harness.dispose();
  });

  for (final policy in [EndpointSchemePolicy.explicitlyApprovedHttp, EndpointSchemePolicy.registeredLocalHttp]) {
    test('${policy.name} starts cache-only and immediate available probe publishes online', () async {
      final connectivity = _ConnectivityMonitor(initialAvailability: Future.value(TransportAvailability.available));
      final harness = _Harness(connectivity: connectivity);
      harness.probes.enqueueCompleted(_validatedEndpoint(policy: policy));
      harness.activations.enqueueSuccess();
      harness.reconciliations.enqueueSuccess();

      await harness.startSession(endpoint: Uri.parse('http://photos.example.test/family/api'), policy: policy);
      await pumpEventQueue();

      expect(harness.probes.identities, hasLength(1));
      expect(harness.coordinator.state.phase, ReachabilityPhase.online);
      expect(mapRemoteMediaAccess(harness.coordinator.state).policy, RemoteMediaPolicy.cacheThenNetwork);
      await harness.dispose();
    });
  }

  test('keeps availability unknown and starts a probe exactly at 750ms', () async {
    final harness = _Harness();
    final probe = harness.probes.enqueuePending();
    await harness.startSession();

    expect(harness.coordinator.state.phase, ReachabilityPhase.unknown);
    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 749));
    await pumpEventQueue();

    expect(harness.probes.identities, isEmpty);
    harness.scheduler.elapse(const Duration(milliseconds: 1));
    await pumpEventQueue();

    expect(harness.probes.identities, [ReachabilityIdentity(sessionEpoch: 0, probeGeneration: 1)]);
    expect(harness.coordinator.state.phase, ReachabilityPhase.probing);
    probe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await harness.dispose();
  });

  test('does not let a late initial snapshot override a newer monitor event', () async {
    final initialAvailability = Completer<TransportAvailability>();
    final connectivity = _ConnectivityMonitor(initialAvailability: initialAvailability.future);
    final harness = _Harness(connectivity: connectivity);
    final probe = harness.probes.enqueuePending();
    final start = harness.coordinator.start();
    await pumpEventQueue();
    final activation = harness.coordinator.activateSession();
    connectivity.emit(TransportAvailability.available);
    initialAvailability.complete(TransportAvailability.unavailable);
    await Future.wait([start, activation]);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();

    expect(harness.probes.identities, hasLength(1));
    expect(harness.coordinator.state.phase, ReachabilityPhase.probing);
    probe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await harness.dispose();
  });

  test('coalesces one real reconnect transition into one rerun', () async {
    final harness = _Harness();
    final firstProbe = harness.probes.enqueuePending();
    final secondProbe = harness.probes.enqueuePending();
    harness.activations.enqueueSuccess();
    harness.reconciliations.enqueueSuccess();
    await harness.startSession();

    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
    harness.connectivity.emit(TransportAvailability.unavailable);
    harness.connectivity.emit(TransportAvailability.available);
    firstProbe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await pumpEventQueue();

    expect(harness.probes.identities, hasLength(1));
    harness.scheduler.elapse(const Duration(milliseconds: 749));
    expect(harness.probes.identities, hasLength(1));
    harness.scheduler.elapse(const Duration(milliseconds: 1));
    await pumpEventQueue();

    expect(harness.probes.identities, hasLength(2));
    secondProbe.complete(_validatedEndpoint());
    await pumpEventQueue();
    expect(harness.activations.requests, hasLength(1));
    expect(harness.reconciliations.requests, hasLength(1));
    await harness.dispose();
  });

  test('duplicate available preserves a pending HTTPS probe without rerun', () async {
    final lease = _RequestContextLease();
    final harness = _Harness(requestContextLease: lease);
    final staleProbe = harness.probes.enqueuePending(completesOnCancel: false);
    harness.activations.enqueueSuccess();
    harness.reconciliations.enqueueSuccess();
    await harness.startSession();

    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
    final staleIdentity = harness.probes.identities.single;
    final transportInvalidations = lease.transportInvalidations;

    harness.connectivity.emit(TransportAvailability.available);

    expect(harness.epochs.current, staleIdentity);
    expect(lease.transportInvalidations, transportInvalidations);
    await pumpEventQueue();
    expect(staleProbe.cancelCount, 0);

    staleProbe.complete(_validatedEndpoint());
    await pumpEventQueue();

    expect(harness.activations.requests, hasLength(1));
    expect(harness.reconciliations.requests, hasLength(1));
    expect(harness.probes.identities, hasLength(1));
    expect(harness.publisher.states.where((state) => state.phase == ReachabilityPhase.online), hasLength(1));
    await harness.dispose();
  });

  test('duplicate available preserves a pending activation without rerun', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    final staleActivation = harness.activations.enqueuePending();
    harness.reconciliations.enqueueSuccess();
    await harness.startSession();

    await harness.runCycle();
    final staleIdentity = harness.activations.requests.single;

    harness.connectivity.emit(TransportAvailability.available);

    expect(harness.epochs.current.probeGeneration, staleIdentity.probeGeneration);
    await pumpEventQueue();
    expect(staleActivation.cancelCount, 0);

    harness.confirmedAccess.proof = _proofFor(staleIdentity.endpoint.apiEndpoint, staleIdentity.endpoint.schemePolicy);
    staleActivation.complete(
      OfflineResult.success(
        EndpointActivationReceipt(
          endpoint: staleIdentity.endpoint,
          sessionEpoch: staleIdentity.sessionEpoch,
          probeGeneration: staleIdentity.probeGeneration,
        ),
      ),
    );
    await pumpEventQueue();

    expect(harness.activations.requests, hasLength(1));
    expect(harness.reconciliations.requests, hasLength(1));
    expect(harness.publisher.states.where((state) => state.phase == ReachabilityPhase.online), hasLength(1));
    await harness.dispose();
  });

  test('duplicate available invalidates a local lease and schedules a replacement probe', () async {
    final connectivity = _ConnectivityMonitor(initialAvailability: Future.value(TransportAvailability.available));
    final lease = _RequestContextLease(localActive: true);
    final harness = _Harness(connectivity: connectivity, requestContextLease: lease);
    harness.probes.enqueuePending();
    final replacementProbe = harness.probes.enqueuePending();

    await harness.startSession();
    connectivity.emit(TransportAvailability.available);

    expect(lease.transportInvalidations, 2);
    expect(lease.blocked, isTrue);
    expect(harness.probes.identities, hasLength(1));
    await pumpEventQueue();
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
    expect(harness.probes.identities, hasLength(2));

    replacementProbe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await harness.dispose();
  });

  test('ignores a probe completion from a stale generation', () async {
    final harness = _Harness();
    final probe = harness.probes.enqueuePending();
    await harness.startSession();
    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();

    harness.epochs.invalidateProbeGeneration();
    probe.complete(_validatedEndpoint());
    await pumpEventQueue();

    expect(harness.activations.requests, isEmpty);
    expect(harness.publisher.states.where((state) => state.phase == ReachabilityPhase.online), isEmpty);
    await harness.dispose();
  });

  test('ignores a probe completion from a stale session epoch', () async {
    final harness = _Harness();
    final probe = harness.probes.enqueuePending();
    await harness.startSession();
    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();

    harness.epochs.invalidateSession();
    probe.complete(_validatedEndpoint());
    await pumpEventQueue();

    expect(harness.activations.requests, isEmpty);
    expect(harness.publisher.states.where((state) => state.phase == ReachabilityPhase.online), isEmpty);
    await harness.dispose();
  });

  test('unavailable invalidates synchronously, cancels work, and publishes offline', () async {
    final harness = _Harness();
    final probe = harness.probes.enqueuePending();
    await harness.startSession();
    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
    final runningIdentity = harness.epochs.current;

    harness.connectivity.emit(TransportAvailability.unavailable);

    expect(harness.coordinator.state.phase, ReachabilityPhase.offline);
    expect(harness.epochs.current, isNot(runningIdentity));
    await pumpEventQueue();
    expect(probe.cancelCount, 1);
    await harness.dispose();
  });

  test('duplicate available while HTTPS is online preserves media access and schedules no replacement probe', () async {
    final lease = _RequestContextLease();
    final harness = _Harness(requestContextLease: lease);
    harness.probes.enqueueCompleted(_validatedEndpoint());
    harness.activations.enqueueSuccess();
    harness.reconciliations.enqueueSuccess();
    await harness.startSession();
    await harness.runCycle();
    final onlineIdentity = harness.epochs.current;
    final transportInvalidations = lease.transportInvalidations;

    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(seconds: 1));
    await pumpEventQueue();

    expect(harness.coordinator.state.phase, ReachabilityPhase.online);
    expect(harness.epochs.current, onlineIdentity);
    expect(lease.transportInvalidations, transportInvalidations);
    expect(harness.probes.identities, hasLength(1));
    expect(harness.scheduler.activeTaskCount, 0);
    await harness.dispose();
  });

  test('available on a new WiFi invalidates online local HTTP and reprobes', () async {
    final lease = _RequestContextLease(localActive: true);
    final harness = _Harness(requestContextLease: lease);
    harness.probes.enqueueCompleted(_validatedEndpoint(policy: EndpointSchemePolicy.registeredLocalHttp));
    harness.activations.enqueueSuccess();
    harness.reconciliations.enqueueSuccess();
    final replacementProbe = harness.probes.enqueuePending();
    await harness.startSession();
    await harness.runCycle();
    final onlineIdentity = harness.epochs.current;
    final invalidations = lease.transportInvalidations;

    harness.connectivity.emit(TransportAvailability.available);

    expect(lease.transportInvalidations, invalidations + 1);
    expect(lease.blocked, isTrue);
    expect(harness.coordinator.state.phase, ReachabilityPhase.probing);
    expect(harness.coordinator.state.confirmedEndpoint, isNull);
    expect(harness.epochs.current, isNot(onlineIdentity));

    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
    expect(harness.probes.identities, hasLength(2));

    replacementProbe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await harness.dispose();
  });

  test('pause cancels pending work and resume schedules a fresh cycle', () async {
    final harness = _Harness();
    final probe = harness.probes.enqueuePending();
    await harness.startSession();
    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 749));

    await harness.coordinator.pause();
    harness.scheduler.elapse(const Duration(seconds: 1));
    await pumpEventQueue();

    expect(harness.coordinator.state.phase, ReachabilityPhase.paused);
    expect(harness.probes.identities, isEmpty);
    harness.coordinator.resume();
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();

    expect(harness.probes.identities, hasLength(1));
    probe.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
    await harness.dispose();
  });

  test('pause publishes paused synchronously and waits for reconciliation cancellation to drain', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    harness.activations.enqueueSuccess();
    final reconciliation = harness.reconciliations.enqueuePending();
    await harness.startSession();
    await harness.runCycle();

    var pauseCompleted = false;
    final pause = harness.coordinator.pause().then((_) => pauseCompleted = true);

    expect(harness.coordinator.state.phase, ReachabilityPhase.paused);
    expect(pauseCompleted, isFalse);
    await pumpEventQueue();
    expect(reconciliation.cancelCount, 1);
    expect(pauseCompleted, isFalse);

    reconciliation.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    await pause;

    expect(pauseCompleted, isTrue);
    await harness.dispose();
  });

  test('logout waits for cancelled activation rollback before returning', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    final activation = harness.activations.enqueuePending();
    await harness.startSession();
    harness.connectivity.emit(TransportAvailability.available);
    harness.scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
    final previousEpoch = harness.epochs.current.sessionEpoch;

    var logoutFinished = false;
    final logout = harness.coordinator.logout().then((_) => logoutFinished = true);
    await pumpEventQueue();

    expect(harness.epochs.current.sessionEpoch, previousEpoch + 1);
    expect(activation.cancelCount, 1);
    expect(logoutFinished, isFalse);
    activation.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    await logout;

    expect(logoutFinished, isTrue);
    expect(harness.coordinator.state.confirmedEndpoint, isNull);
    await harness.dispose();
  });

  test('dispose marks disposed synchronously and releases every resource once', () async {
    final harness = _Harness();
    await harness.startSession();
    harness.connectivity.emit(TransportAvailability.available);

    final disposal = harness.coordinator.dispose();

    expect(harness.coordinator.state.phase, ReachabilityPhase.disposed);
    await disposal;
    await harness.coordinator.dispose();

    expect(harness.scheduler.activeTaskCount, 0);
    expect(harness.connectivity.cancelCount, 1);
    expect(harness.connectivity.disposeCount, 1);
  });

  test('reuses one monitor across login, logout, login, and dispose', () async {
    final harness = _Harness();

    await Future.wait([harness.coordinator.start(), harness.coordinator.start()]);
    await harness.coordinator.activateSession();
    await harness.coordinator.logout();
    await harness.coordinator.activateSession();
    await harness.coordinator.dispose();

    expect(harness.connectivity.listenCount, 1);
    expect(harness.connectivity.cancelCount, 1);
    expect(harness.connectivity.disposeCount, 1);
    expect(harness.scheduler.activeTaskCount, 0);
  });

  test('publishes offline when a cycle has no valid candidates', () async {
    final lease = _RequestContextLease();
    final harness = _Harness(requestContextLease: lease);
    harness.probes.enqueueCompleted(const EndpointProbeResult.rejected(OfflineErrorCode.serverUnavailable));
    await harness.startSession();

    await harness.runCycle();

    expect(harness.coordinator.state.phase, ReachabilityPhase.offline);
    expect(harness.activations.requests, isEmpty);
    expect(lease.validationFailureInvalidations, 1);
    await harness.dispose();
  });

  test('publishes offline when endpoint activation fails', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    harness.activations.enqueueFailure(OfflineErrorCode.serverUnavailable);
    await harness.startSession();

    await harness.runCycle();

    expect(harness.coordinator.state.phase, ReachabilityPhase.offline);
    expect(harness.reconciliations.requests, isEmpty);
    await harness.dispose();
  });

  test('keeps online state when reconciliation fails', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    harness.activations.enqueueSuccess();
    harness.reconciliations.enqueueFailure(OfflineErrorCode.serverUnavailable);
    await harness.startSession();

    await harness.runCycle();

    expect(harness.coordinator.state.phase, ReachabilityPhase.online);
    expect(harness.reconciliations.requests.single.probeGeneration, harness.epochs.current.probeGeneration);
    await harness.dispose();
  });

  test('maps a thrown probe exception to offline without activation', () async {
    final harness = _Harness();
    harness.probes.enqueueException(
      StateError(
        'probe failed at https://photos.example.test/api; '
        'Authorization: Bearer bearer-secret; '
        'Proxy-Authorization=Basic dXNlcjpwYXNz; '
        'token=token-secret; Cookie: session=cookie-secret',
      ),
    );
    await harness.startSession();

    await harness.runCycle();

    expect(harness.coordinator.state.phase, ReachabilityPhase.offline);
    expect(harness.activations.requests, isEmpty);
    final failure = harness.failures.failures.single;
    expect(failure.code, ReachabilityFailureCode.probeException);
    expect(failure.reason, ReachabilityFailureReason.exception);
    expect(failure.causeType, 'StateError');
    expect(failure.causeMessage, contains('probe failed'));
    expect(failure.causeMessage, isNot(contains('https://photos.example.test/api')));
    expect(failure.causeMessage, isNot(contains('bearer-secret')));
    expect(failure.causeMessage, isNot(contains('dXNlcjpwYXNz')));
    expect(failure.causeMessage, isNot(contains('token-secret')));
    expect(failure.causeMessage, isNot(contains('cookie-secret')));
    expect(
      failure.causeMessage,
      'Bad state: probe failed at [redacted-url] authorization=[redacted] '
      'proxy-authorization=[redacted] token=[redacted] cookie=[redacted]',
    );
    expect(failure.stackTrace, isNotNull);
    await harness.dispose();
  });

  test('sanitizer redacts folded credential headers and bare authentication schemes', () {
    final sanitized = sanitizeReachabilityFailureMessage(
      'probe failed with Bearer bare-bearer and Basic bare-basic\r\n'
      'Authorization:\r\n Bearer folded-bearer\r\n'
      'Cookie: session=cookie-secret; Path=/\r\n'
      'Set-Cookie: refresh=set-cookie-secret; HttpOnly\r\n'
      'Proxy-Authorization: Basic folded-basic',
    );

    for (final secret in [
      'folded-bearer',
      'cookie-secret',
      'set-cookie-secret',
      'folded-basic',
      'bare-bearer',
      'bare-basic',
    ]) {
      expect(sanitized, isNot(contains(secret)));
    }
    expect(sanitized, contains('authorization=[redacted]'));
    expect(sanitized, contains('cookie=[redacted]'));
    expect(sanitized, contains('set-cookie=[redacted]'));
    expect(sanitized, contains('proxy-authorization=[redacted]'));
    expect(sanitized, contains('[redacted-auth]'));
  });

  test('availability event owns and reports pipeline cancellation failure without a zone error', () async {
    final uncaught = <Object>[];
    late _Harness harness;
    late _ControlledRequest<EndpointProbeResult> pending;
    final cancelError = StateError('transport review cancel failed');

    await runZonedGuarded(() async {
      harness = _Harness();
      pending = harness.probes.enqueuePending(cancelError: cancelError, completesOnCancel: false);
      await harness.startSession();
      harness.connectivity.emit(TransportAvailability.available);
      harness.scheduler.elapse(const Duration(milliseconds: 750));
      await pumpEventQueue();

      harness.connectivity.emit(TransportAvailability.unavailable);
      pending.complete(const EndpointProbeResult.rejected(OfflineErrorCode.cancelled));
      await pumpEventQueue();

      final failure = harness.failures.failures.singleWhere(
        (failure) => failure.code == ReachabilityFailureCode.transportReviewCancellationException,
      );
      expect(failure.causeType, 'StateError');
      expect(failure.causeMessage, contains('transport review cancel failed'));
      expect(failure.stackTrace, isNotNull);
      await harness.dispose();
    }, (error, _) => uncaught.add(error));

    expect(uncaught, isEmpty);
  });

  test('maps a thrown activation exception to offline without reconciliation', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    harness.activations.enqueueException(StateError('activation failed'));
    await harness.startSession();

    await harness.runCycle();

    expect(harness.coordinator.state.phase, ReachabilityPhase.offline);
    expect(harness.reconciliations.requests, isEmpty);
    await harness.dispose();
  });

  test('keeps online and does not rerun when reconciliation throws', () async {
    final harness = _Harness();
    harness.probes.enqueueCompleted(_validatedEndpoint());
    harness.activations.enqueueSuccess();
    harness.reconciliations.enqueueException(StateError('reconciliation failed'));
    await harness.startSession();

    await harness.runCycle();
    harness.scheduler.elapse(const Duration(seconds: 1));
    await pumpEventQueue();

    expect(harness.coordinator.state.phase, ReachabilityPhase.online);
    expect(harness.probes.identities, hasLength(1));
    expect(harness.reconciliations.requests, hasLength(1));
    await harness.dispose();
  });

  for (final stage in _CancellationStage.values) {
    test('dispose awaits a late ${stage.name} result and cleans up after cancel throws', () async {
      final harness = _Harness();
      final cancelError = StateError('${stage.name} cancel failed');
      harness.connectivity.disposeError = ArgumentError('monitor dispose failed');
      late final _ControlledRequest<Object?> pending;
      switch (stage) {
        case _CancellationStage.probe:
          pending = harness.probes.enqueuePending(cancelError: cancelError);
        case _CancellationStage.activation:
          harness.probes.enqueueCompleted(_validatedEndpoint());
          pending = harness.activations.enqueuePending(cancelError: cancelError);
        case _CancellationStage.reconciliation:
          harness.probes.enqueueCompleted(_validatedEndpoint());
          harness.activations.enqueueSuccess();
          pending = harness.reconciliations.enqueuePending(cancelError: cancelError);
      }
      await harness.startSession();
      harness.connectivity.emit(TransportAvailability.available);
      harness.scheduler.elapse(const Duration(milliseconds: 750));
      await pumpEventQueue();

      var settled = false;
      final disposal = harness.coordinator.dispose();
      unawaited(disposal.then<void>((_) => settled = true, onError: (_) => settled = true));
      final errorExpectation = expectLater(disposal, throwsA(same(cancelError)));
      await pumpEventQueue();

      expect(pending.cancelCount, 1);
      expect(settled, isFalse);
      pending.complete(_cancelledResult(stage));
      await errorExpectation;

      expect(harness.connectivity.cancelCount, 1);
      expect(harness.connectivity.disposeCount, 1);
      expect(harness.scheduler.activeTaskCount, 0);
    });
  }
}

final class _Harness {
  _Harness({_ConnectivityMonitor? connectivity, RequestContextLeasePort? requestContextLease})
    : connectivity = connectivity ?? _ConnectivityMonitor(),
      requestContextLease = requestContextLease ?? const _NoopRequestContextLease();

  final scheduler = ManualReachabilityScheduler();
  final epochs = SessionEpochController();
  final _ConnectivityMonitor connectivity;
  final RequestContextLeasePort requestContextLease;
  final probes = _ProbeCycles();
  final confirmedAccess = _ConfirmedAccess();
  late final activations = _Activations(confirmedAccess);
  final reconciliations = _Reconciliations();
  final publisher = _Publisher();
  final failures = _FailureReporter();

  late final coordinator = ServerReachabilityCoordinator(
    epochs: epochs,
    connectivity: connectivity,
    probeCycles: probes,
    activations: activations,
    reconciliations: reconciliations,
    statePublisher: publisher,
    scheduler: scheduler,
    requestContextLease: requestContextLease,
    confirmedServerAccess: confirmedAccess,
    failureReporter: failures,
  );

  Future<void> startSession({Uri? endpoint, EndpointSchemePolicy policy = EndpointSchemePolicy.httpsOnly}) async {
    await coordinator.start();
    final activeEndpoint = endpoint ?? Uri.parse('https://cached.example.test/api');
    confirmedAccess.proof = _proofFor(activeEndpoint, policy);
    await coordinator.activateSession(confirmedEndpoint: activeEndpoint);
  }

  Future<void> runCycle() async {
    connectivity.emit(TransportAvailability.available);
    scheduler.elapse(const Duration(milliseconds: 750));
    await pumpEventQueue();
  }

  Future<void> dispose() => coordinator.dispose();
}

final class _FailureReporter implements ReachabilityFailureReporterPort {
  final failures = <ReachabilityFailure>[];

  @override
  void report(ReachabilityFailure failure) => failures.add(failure);
}

final class _RequestContextLease implements RequestContextLeasePort {
  _RequestContextLease({this.localActive = false});

  final bool localActive;
  var transportInvalidations = 0;
  var validationFailureInvalidations = 0;
  var blocked = false;

  @override
  RequestContextActivationLease? beginActivation(EndpointSchemePolicy policy) => null;

  @override
  bool commitActivation(RequestContextActivationLease lease) => false;

  @override
  bool isCurrent(RequestContextActivationLease lease) => false;

  @override
  void abandonActivation(RequestContextActivationLease lease) {}

  @override
  bool invalidateForTransportReview() {
    if (!localActive) return false;
    transportInvalidations++;
    blocked = true;
    return true;
  }

  @override
  void invalidateAfterValidationFailure() {
    validationFailureInvalidations++;
    blocked = true;
  }
}

final class _NoopRequestContextLease implements RequestContextLeasePort {
  const _NoopRequestContextLease();

  @override
  RequestContextActivationLease? beginActivation(EndpointSchemePolicy policy) => null;

  @override
  bool commitActivation(RequestContextActivationLease lease) => false;

  @override
  bool isCurrent(RequestContextActivationLease lease) => false;

  @override
  void abandonActivation(RequestContextActivationLease lease) {}

  @override
  bool invalidateForTransportReview() => false;

  @override
  void invalidateAfterValidationFailure() {}
}

final class _ConnectivityMonitor implements ConnectivityMonitorPort {
  _ConnectivityMonitor({Future<TransportAvailability>? initialAvailability})
    : _initialAvailability = initialAvailability ?? Future.value(TransportAvailability.unknown) {
    _controller.onListen = () => listenCount++;
    _controller.onCancel = () => cancelCount++;
  }

  final StreamController<TransportAvailability> _controller = StreamController.broadcast(sync: true);
  final Future<TransportAvailability> _initialAvailability;
  int listenCount = 0;
  int cancelCount = 0;
  int disposeCount = 0;
  Object? disposeError;

  @override
  Future<TransportAvailability> get initialAvailability => _initialAvailability;

  @override
  Stream<TransportAvailability> get events => _controller.stream;

  void emit(TransportAvailability availability) => _controller.add(availability);

  @override
  Future<void> dispose() async {
    disposeCount++;
    await _controller.close();
    final error = disposeError;
    if (error != null) {
      throw error;
    }
  }
}

final class _ProbeCycles implements EndpointProbeCyclePort {
  final Queue<CancellableRequest<EndpointProbeResult>> _operations = Queue();
  final List<ReachabilityIdentity> identities = [];

  _ControlledRequest<EndpointProbeResult> enqueuePending({Object? cancelError, bool? completesOnCancel}) {
    final operation = _ControlledRequest<EndpointProbeResult>(
      const EndpointProbeResult.rejected(OfflineErrorCode.cancelled),
      completesOnCancel: completesOnCancel ?? cancelError == null,
      cancelError: cancelError,
    );
    _operations.add(operation);
    return operation;
  }

  void enqueueCompleted(EndpointProbeResult result) => _operations.add(_ControlledRequest.completed(result));

  void enqueueException(Object error) => _operations.add(_ThrowingRequest(error));

  @override
  CancellableRequest<EndpointProbeResult> begin(ReachabilityIdentity identity) {
    identities.add(identity);
    return _operations.removeFirst();
  }
}

final class _Activations implements EndpointActivationPort {
  _Activations(this.confirmedAccess);

  final _ConfirmedAccess confirmedAccess;
  final Queue<CancellableRequest<OfflineResult<EndpointActivationReceipt>>> _operations = Queue();
  final List<EndpointActivationRequest> requests = [];

  _ControlledRequest<OfflineResult<EndpointActivationReceipt>> enqueuePending({Object? cancelError}) {
    final operation = _ControlledRequest<OfflineResult<EndpointActivationReceipt>>(
      const OfflineResult.failure(OfflineErrorCode.cancelled),
      completesOnCancel: false,
      cancelError: cancelError,
    );
    _operations.add(operation);
    return operation;
  }

  void enqueueSuccess() => _operations.add(_ReceiptRequest());

  void enqueueFailure(OfflineErrorCode error) {
    _operations.add(_ControlledRequest.completed(OfflineResult.failure(error)));
  }

  void enqueueException(Object error) => _operations.add(_ThrowingRequest(error));

  @override
  CancellableRequest<OfflineResult<EndpointActivationReceipt>> activate(EndpointActivationRequest request) {
    requests.add(request);
    final operation = _operations.removeFirst();
    if (operation is _ReceiptRequest) {
      confirmedAccess.proof = _proofFor(request.endpoint.apiEndpoint, request.endpoint.schemePolicy);
      operation.complete(
        OfflineResult.success(
          EndpointActivationReceipt(
            endpoint: request.endpoint,
            sessionEpoch: request.sessionEpoch,
            probeGeneration: request.probeGeneration,
          ),
        ),
      );
    }
    return operation;
  }
}

final class _ConfirmedAccess implements ConfirmedServerAccessPort {
  ConfirmedServerAccess? proof;

  @override
  ConfirmedServerAccess? read() => proof;
}

ConfirmedServerAccess _proofFor(Uri endpoint, EndpointSchemePolicy policy) {
  return ConfirmedServerAccess(
    apiEndpoint: endpoint,
    canonicalOrigin: Uri.parse(endpoint.origin),
    schemePolicy: policy,
    nativeContextGeneration: 11,
    confirmed: true,
    fenced: false,
  );
}

final class _Reconciliations implements ReconciliationPort {
  final Queue<CancellableRequest<OfflineResult<OperationCompletion>>> _operations = Queue();
  final List<ReconciliationRequest> requests = [];

  void enqueueSuccess() {
    _operations.add(_ControlledRequest.completed(const OfflineResult.success(OperationCompletion.completed)));
  }

  void enqueueFailure(OfflineErrorCode error) {
    _operations.add(_ControlledRequest.completed(OfflineResult.failure(error)));
  }

  _ControlledRequest<OfflineResult<OperationCompletion>> enqueuePending({Object? cancelError}) {
    final operation = _ControlledRequest<OfflineResult<OperationCompletion>>(
      const OfflineResult.failure(OfflineErrorCode.cancelled),
      completesOnCancel: false,
      cancelError: cancelError,
    );
    _operations.add(operation);
    return operation;
  }

  void enqueueException(Object error) => _operations.add(_ThrowingRequest(error));

  @override
  CancellableRequest<OfflineResult<OperationCompletion>> reconcile(ReconciliationRequest request) {
    requests.add(request);
    return _operations.removeFirst();
  }
}

final class _Publisher implements ReachabilityStatePublisherPort {
  final List<ReachabilityState> states = [];

  @override
  void publish(ReachabilityState state) => states.add(state);
}

class _ControlledRequest<T> implements CancellableRequest<T> {
  _ControlledRequest(this._cancelResult, {this.completesOnCancel = true, this.cancelError});

  _ControlledRequest.completed(T value) : _cancelResult = value, completesOnCancel = true, cancelError = null {
    _completion.complete(value);
  }

  final T _cancelResult;
  final bool completesOnCancel;
  final Object? cancelError;
  final Completer<T> _completion = Completer();
  int cancelCount = 0;

  @override
  Future<T> get result => _completion.future;

  void complete(T value) {
    if (!_completion.isCompleted) {
      _completion.complete(value);
    }
  }

  @override
  Future<void> cancel() async {
    cancelCount++;
    final error = cancelError;
    if (error != null) {
      throw error;
    }
    if (completesOnCancel) {
      complete(_cancelResult);
    }
  }
}

final class _ThrowingRequest<T> implements CancellableRequest<T> {
  _ThrowingRequest(this.error);

  final Object error;

  @override
  Future<T> get result => Future.error(error);

  @override
  Future<void> cancel() async {}
}

final class _ReceiptRequest extends _ControlledRequest<OfflineResult<EndpointActivationReceipt>> {
  _ReceiptRequest() : super(const OfflineResult.failure(OfflineErrorCode.cancelled));
}

ValidatedEndpointProbeResult _validatedEndpoint({EndpointSchemePolicy policy = EndpointSchemePolicy.httpsOnly}) {
  final origin = policy == EndpointSchemePolicy.httpsOnly
      ? Uri.parse('https://photos.example.test')
      : Uri.parse('http://photos.example.test');
  return ValidatedEndpointProbeResult(
    canonicalOrigin: origin,
    apiEndpoint: origin.replace(path: '/family/api'),
    userId: 'user-1',
    schemePolicy: policy,
  );
}

enum _CancellationStage { probe, activation, reconciliation }

Object? _cancelledResult(_CancellationStage stage) {
  return switch (stage) {
    _CancellationStage.probe => const EndpointProbeResult.rejected(OfflineErrorCode.cancelled),
    _CancellationStage.activation => const OfflineResult<EndpointActivationReceipt>.failure(OfflineErrorCode.cancelled),
    _CancellationStage.reconciliation => const OfflineResult<OperationCompletion>.failure(OfflineErrorCode.cancelled),
  };
}
