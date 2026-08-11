import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart' as domain;
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/original_export_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/owned_temporary_file_lease.dart';
import 'package:immich_mobile/platform/original_export_api.g.dart' as pigeon;

typedef TemporaryFileLeaseFactory =
    Future<TemporaryFileLease> Function(String path, String leaseToken, NativeLeaseReleaser releaseNativeLease);
typedef OriginalExportFlutterApiRegistration = void Function(pigeon.OriginalExportFlutterApi? api);
typedef RegisteredLocalHttpRetryLeaseVerifier =
    Future<bool> Function(
      domain.OriginalExportContextBinding initiating,
      domain.OriginalExportContextBinding candidate,
    );
typedef OriginalExportFailureReporter = void Function(domain.OriginalExportFailureEvent event);

final class OriginalExportSessionSnapshot {
  const OriginalExportSessionSnapshot({required this.reachability, required this.sessionActive, this.binding});

  final ReachabilityState reachability;
  final bool sessionActive;
  final domain.OriginalExportContextBinding? binding;

  bool authorizes(Uri resource) {
    final proof = binding;
    if (!sessionActive || reachability.phase != ReachabilityPhase.online || proof == null) {
      return false;
    }
    if (_origin(resource) != proof.exactOrigin) {
      return false;
    }
    final endpointPath = proof.apiEndpoint.path.endsWith('/') ? proof.apiEndpoint.path : '${proof.apiEndpoint.path}/';
    return resource.path.startsWith(endpointPath);
  }

  static Uri _origin(Uri uri) => Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
}

final class NativeOriginalExportAdapter implements pigeon.OriginalExportFlutterApi {
  NativeOriginalExportAdapter({
    required OriginalExportHostApi api,
    required TransportAvailability Function() readTransportAvailability,
    required OriginalExportSessionSnapshot Function() readSessionSnapshot,
    required RegisteredLocalHttpRetryLeaseVerifier verifyRegisteredLocalHttpRetryLease,
    required TemporaryFileLeaseFactory leaseFactory,
    OriginalExportFailureReporter? reportFailure,
    OriginalExportFlutterApiRegistration? registerFlutterApi,
  }) : _api = api,
       _readTransportAvailability = readTransportAvailability,
       _readSessionSnapshot = readSessionSnapshot,
       _verifyRegisteredLocalHttpRetryLease = verifyRegisteredLocalHttpRetryLease,
       _leaseFactory = leaseFactory,
       _reportFailure = reportFailure ?? _ignoreFailure,
       _registerFlutterApi = registerFlutterApi ?? pigeon.OriginalExportFlutterApi.setUp {
    _registerFlutterApi(this);
  }

  final OriginalExportHostApi _api;
  final TransportAvailability Function() _readTransportAvailability;
  final OriginalExportSessionSnapshot Function() _readSessionSnapshot;
  final RegisteredLocalHttpRetryLeaseVerifier _verifyRegisteredLocalHttpRetryLease;
  final TemporaryFileLeaseFactory _leaseFactory;
  final OriginalExportFailureReporter _reportFailure;
  final OriginalExportFlutterApiRegistration _registerFlutterApi;
  final Map<int, _OriginalExportOperation> _operations = {};
  final Set<int> _retiringRequestIds = {};
  final Map<int, Future<void>> _retiringCancellations = {};
  int _nextRequestId = 1;
  bool _disposed = false;
  bool _flutterApiRegistered = true;
  bool _cancellingAll = false;
  Future<void>? _cancelAllFuture;
  Future<void>? _disposeFuture;

  late final LocalOriginalExportPort local = _LocalOriginalExportPort(this);
  late final RemoteOriginalExportPort remote = _RemoteOriginalExportPort(this);

  CancellableRequest<domain.OriginalExportResult> exportLocal(domain.LocalOriginalExportRequest request) {
    final operation = _newOperation();
    if (!_accept(operation)) {
      return operation;
    }
    unawaited(_dispatchLocal(request, operation));
    return operation;
  }

  CancellableRequest<domain.OriginalExportResult> exportRemote(domain.RemoteOriginalExportRequest request) {
    final operation = _newOperation();
    if (!_accept(operation)) {
      return operation;
    }
    final snapshot = _readSessionSnapshot();
    final binding = snapshot.binding;
    if (!snapshot.authorizes(request.resource) || binding == null) {
      _operations.remove(operation.operationId);
      _report(
        phase: domain.OriginalExportFailurePhase.admission,
        error: domain.OriginalExportError.serverUnavailable,
        attempt: 1,
        initiating: binding,
      );
      operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.serverUnavailable));
      return operation;
    }
    unawaited(_dispatchRemote(request, binding, operation));
    return operation;
  }

  Future<void> cancelAll() {
    final active = _cancelAllFuture;
    if (active != null) {
      return active;
    }
    return _cancelAllFuture = _cancelEveryOperation().whenComplete(() => _cancelAllFuture = null);
  }

  Future<void> dispose() {
    final active = _disposeFuture;
    if (active != null) {
      return active;
    }
    _disposed = true;
    return _disposeFuture = _disposeResources();
  }

  @override
  void onProgress(pigeon.OriginalExportProgress progress) {
    if (progress.requestId <= 0 || !progress.fraction.isFinite || progress.fraction < 0 || progress.fraction > 1) {
      return;
    }
  }

  _OriginalExportOperation _newOperation() {
    final requestId = _allocateRequestId();
    return _OriginalExportOperation(requestId, _cancelRequest);
  }

  int _allocateRequestId() {
    while (_operations.containsKey(_nextRequestId) || _retiringRequestIds.contains(_nextRequestId)) {
      _nextRequestId++;
    }
    return _nextRequestId++;
  }

  bool _accept(_OriginalExportOperation operation) {
    if (_disposed || _cancellingAll) {
      operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.cancelled));
      return false;
    }
    _operations[operation.operationId] = operation;
    return true;
  }

  Future<void> _dispatchLocal(domain.LocalOriginalExportRequest request, _OriginalExportOperation operation) async {
    final policy =
        request.policy == domain.LocalOriginalExportPolicy.allowICloud &&
            _readTransportAvailability() == TransportAvailability.available
        ? pigeon.OriginalExportPolicy.allowICloud
        : pigeon.OriginalExportPolicy.localOnly;
    final requestId = operation.activeRequestId!;
    try {
      final result = await _api.exportLocal(
        pigeon.LocalOriginalExportRequest(
          requestId: requestId,
          assetId: request.assetId,
          suggestedName: request.suggestedFilename,
          policy: policy,
        ),
      );
      operation.finishNativeAttempt(requestId);
      final mappedError = result.error == null ? null : _mapError(result.error!);
      if (mappedError != null) {
        _report(phase: domain.OriginalExportFailurePhase.native, error: mappedError, attempt: 1, initiating: null);
      }
      await _handleResult(operation, result, attempt: 1, initiating: null);
    } on Object {
      operation.finishNativeAttempt(requestId);
      _report(
        phase: domain.OriginalExportFailurePhase.native,
        error: domain.OriginalExportError.storageUnavailable,
        attempt: 1,
        initiating: null,
      );
      _completeFailure(operation, domain.OriginalExportError.storageUnavailable);
    }
  }

  Future<void> _dispatchRemote(
    domain.RemoteOriginalExportRequest request,
    domain.OriginalExportContextBinding initiating,
    _OriginalExportOperation operation,
  ) async {
    var binding = initiating;
    for (var attempt = 1; attempt <= 2; attempt++) {
      final requestId = operation.activeRequestId;
      if (requestId == null || operation.isCancellationRequested || !_isCurrent(operation)) {
        _completeFailure(operation, domain.OriginalExportError.cancelled);
        return;
      }

      final pigeon.OriginalExportResult result;
      try {
        result = await _api.exportRemote(_remotePigeonRequest(request, binding, requestId));
      } on Object {
        operation.finishNativeAttempt(requestId);
        _report(
          phase: domain.OriginalExportFailurePhase.native,
          error: domain.OriginalExportError.serverUnavailable,
          attempt: attempt,
          initiating: initiating,
        );
        _completeFailure(operation, domain.OriginalExportError.serverUnavailable);
        return;
      }
      operation.finishNativeAttempt(requestId);

      if (operation.isCancellationRequested || !_isCurrent(operation)) {
        await _releaseReturnedToken(result.leaseToken);
        _completeFailure(operation, domain.OriginalExportError.cancelled);
        return;
      }

      final canonicalStaleFailure =
          result.path == null &&
          result.leaseToken == null &&
          result.error == pigeon.OriginalExportErrorCode.staleContext;
      if (canonicalStaleFailure && attempt == 1) {
        final retryBinding = await _retryBinding(initiating, operation);
        if (retryBinding != null &&
            _readTransportAvailability() == TransportAvailability.available &&
            operation.beginNativeAttempt(_allocateRequestId())) {
          binding = retryBinding;
          continue;
        }
      }

      final mappedError = result.error == null ? null : _mapError(result.error!);
      if (mappedError != null) {
        _report(
          phase: attempt == 1 ? domain.OriginalExportFailurePhase.native : domain.OriginalExportFailurePhase.retry,
          error: mappedError,
          attempt: attempt,
          initiating: initiating,
        );
      }
      await _handleResult(
        operation,
        result,
        attempt: attempt,
        initiating: initiating,
        presentationClaim: domain.OriginalExportPresentationClaim(
          () => _claimPresentation(binding, request.resource, attempt),
        ),
      );
      return;
    }
  }

  pigeon.RemoteOriginalExportRequest _remotePigeonRequest(
    domain.RemoteOriginalExportRequest request,
    domain.OriginalExportContextBinding binding,
    int requestId,
  ) {
    return pigeon.RemoteOriginalExportRequest(
      requestId: requestId,
      url: request.resource.toString(),
      origin: binding.exactOrigin.toString(),
      apiEndpoint: binding.apiEndpoint.toString(),
      sessionEpoch: binding.sessionEpoch,
      expectedContextGeneration: binding.expectedContextGeneration,
      schemePolicy: switch (binding.schemePolicy) {
        EndpointSchemePolicy.httpsOnly => pigeon.OriginalExportSchemePolicy.httpsOnly,
        EndpointSchemePolicy.explicitlyApprovedHttp => pigeon.OriginalExportSchemePolicy.explicitlyApprovedHttp,
        EndpointSchemePolicy.registeredLocalHttp => pigeon.OriginalExportSchemePolicy.registeredLocalHttp,
      },
      suggestedName: request.suggestedFilename,
    );
  }

  Future<domain.OriginalExportContextBinding?> _retryBinding(
    domain.OriginalExportContextBinding initiating,
    _OriginalExportOperation operation,
  ) async {
    if (initiating.schemePolicy != EndpointSchemePolicy.registeredLocalHttp ||
        operation.isCancellationRequested ||
        _readTransportAvailability() != TransportAvailability.available) {
      return null;
    }
    final candidateSnapshot = _readSessionSnapshot();
    final candidate = candidateSnapshot.binding;
    if (candidate == null ||
        !candidateSnapshot.sessionActive ||
        candidateSnapshot.reachability.phase != ReachabilityPhase.online ||
        !initiating.sameSessionAndEndpoint(candidate) ||
        candidate.expectedContextGeneration == initiating.expectedContextGeneration) {
      return null;
    }
    if (!await _verifyRegisteredLocalHttpRetryLease(initiating, candidate) ||
        operation.isCancellationRequested ||
        _readTransportAvailability() != TransportAvailability.available) {
      return null;
    }
    final confirmedSnapshot = _readSessionSnapshot();
    if (!confirmedSnapshot.sessionActive ||
        confirmedSnapshot.reachability.phase != ReachabilityPhase.online ||
        confirmedSnapshot.binding != candidate ||
        _readTransportAvailability() != TransportAvailability.available) {
      return null;
    }
    return candidate;
  }

  bool _claimPresentation(domain.OriginalExportContextBinding binding, Uri resource, int attempt) {
    final snapshot = _readSessionSnapshot();
    final claimed = snapshot.binding == binding && snapshot.authorizes(resource);
    if (!claimed) {
      _report(
        phase: domain.OriginalExportFailurePhase.presentation,
        error: domain.OriginalExportError.staleContext,
        attempt: attempt,
        initiating: binding,
      );
    }
    return claimed;
  }

  bool _isCurrent(_OriginalExportOperation operation) => identical(_operations[operation.operationId], operation);

  void _report({
    required domain.OriginalExportFailurePhase phase,
    required domain.OriginalExportError error,
    required int attempt,
    required domain.OriginalExportContextBinding? initiating,
  }) {
    _reportFailure(
      domain.OriginalExportFailureEvent(
        phase: phase,
        errorCode: error,
        attempt: attempt,
        sessionRelation: _sessionRelation(initiating, _readSessionSnapshot().binding),
      ),
    );
  }

  static domain.OriginalExportSessionRelation _sessionRelation(
    domain.OriginalExportContextBinding? initiating,
    domain.OriginalExportContextBinding? current,
  ) {
    if (initiating == null || current == null) {
      return domain.OriginalExportSessionRelation.unavailable;
    }
    if (initiating.sessionEpoch != current.sessionEpoch) {
      return domain.OriginalExportSessionRelation.sessionChanged;
    }
    if (!initiating.sameSessionAndEndpoint(current)) {
      return domain.OriginalExportSessionRelation.endpointChanged;
    }
    if (initiating.expectedContextGeneration != current.expectedContextGeneration) {
      return domain.OriginalExportSessionRelation.generationAdvanced;
    }
    return domain.OriginalExportSessionRelation.current;
  }

  static void _ignoreFailure(domain.OriginalExportFailureEvent _) {}

  Future<void> _handleResult(
    _OriginalExportOperation operation,
    pigeon.OriginalExportResult result, {
    required int attempt,
    required domain.OriginalExportContextBinding? initiating,
    domain.OriginalExportPresentationClaim? presentationClaim,
  }) async {
    final path = result.path;
    final leaseToken = result.leaseToken;
    final error = result.error;
    final isFailure = path == null && leaseToken == null && error != null;
    final isSuccess =
        path != null && path.trim().isNotEmpty && leaseToken != null && leaseToken.trim().isNotEmpty && error == null;
    if (!isFailure && !isSuccess) {
      await _releaseReturnedToken(leaseToken);
      if (_removeIfCurrent(operation)) {
        _report(
          phase: domain.OriginalExportFailurePhase.adoption,
          error: domain.OriginalExportError.writeFailed,
          attempt: attempt,
          initiating: initiating,
        );
        operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.writeFailed));
      }
      return;
    }
    if (error != null) {
      if (_removeIfCurrent(operation)) {
        operation.complete(domain.OriginalExportResult.failure(_mapError(error)));
      }
      return;
    }

    TemporaryFileLease lease;
    try {
      lease = await _leaseFactory(path!, leaseToken!, _releaseNativeLease);
    } on Object {
      await _releaseReturnedToken(leaseToken);
      if (_removeIfCurrent(operation)) {
        _report(
          phase: domain.OriginalExportFailurePhase.adoption,
          error: domain.OriginalExportError.storageUnavailable,
          attempt: attempt,
          initiating: initiating,
        );
        operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.storageUnavailable));
      }
      return;
    }
    if (!_removeIfCurrent(operation) ||
        !operation.complete(domain.OriginalExportResult.success(lease, presentationClaim: presentationClaim))) {
      await _releaseLateLease(lease);
    }
  }

  Future<void> _releaseLateLease(TemporaryFileLease lease) async {
    try {
      await lease.release();
    } on Object {
      return;
    }
  }

  Future<void> _releaseReturnedToken(String? leaseToken) async {
    if (leaseToken == null || leaseToken.trim().isEmpty) {
      return;
    }
    try {
      await _releaseNativeLease(leaseToken);
    } on Object {
      return;
    }
  }

  Future<void> _releaseNativeLease(String leaseToken) async {
    final result = await _api.releaseLease(leaseToken);
    if (result.error != null) {
      throw StateError('Native export lease release failed');
    }
  }

  Future<void> _cancelRequest(_OriginalExportOperation operation) async {
    operation.requestCancellation();
    if (!_isCurrent(operation)) {
      return;
    }
    final requestId = operation.activeRequestId;
    if (requestId == null) {
      _completeFailure(operation, domain.OriginalExportError.cancelled);
      return;
    }
    _retiringRequestIds.add(requestId);
    late final Future<void> cancellation;
    cancellation = _cancelAndAwaitTerminal(operation, requestId).whenComplete(() {
      if (identical(_retiringCancellations[requestId], cancellation)) {
        _retiringCancellations.remove(requestId);
        _retiringRequestIds.remove(requestId);
      }
    });
    _retiringCancellations[requestId] = cancellation;
    await cancellation;
  }

  Future<void> _cancelAndAwaitTerminal(_OriginalExportOperation operation, int requestId) async {
    await _api.cancelRequest(requestId);
    await operation.result;
  }

  Future<void> _cancelEveryOperation() async {
    _cancellingAll = true;
    final operations = _operations.values.toList(growable: false);
    final retiring = _retiringCancellations.values.toList(growable: false);
    final activeRequestIds = <int>[];
    for (final operation in operations) {
      operation.requestCancellation();
      final requestId = operation.activeRequestId;
      if (requestId != null) {
        activeRequestIds.add(requestId);
        _retiringRequestIds.add(requestId);
      } else {
        _completeFailure(operation, domain.OriginalExportError.cancelled);
      }
    }
    Object? error;
    StackTrace? stackTrace;
    try {
      await _api.cancelAll();
      await Future.wait(operations.map((operation) => operation.result));
    } on Object catch (caught, caughtStackTrace) {
      error = caught;
      stackTrace = caughtStackTrace;
    }
    try {
      await Future.wait(retiring);
    } finally {
      for (final requestId in activeRequestIds) {
        if (!_retiringCancellations.containsKey(requestId)) {
          _retiringRequestIds.remove(requestId);
        }
      }
      _cancellingAll = false;
    }
    if (error != null) {
      Error.throwWithStackTrace(error, stackTrace!);
    }
  }

  Future<void> _disposeResources() async {
    Object? firstError;
    StackTrace? firstStackTrace;
    Future<void> attempt(Future<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(cancelAll);
    await attempt(_api.dispose);
    if (_flutterApiRegistered) {
      _flutterApiRegistered = false;
      try {
        _registerFlutterApi(null);
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void _completeFailure(_OriginalExportOperation operation, domain.OriginalExportError error) {
    if (_removeIfCurrent(operation)) {
      operation.complete(domain.OriginalExportResult.failure(error));
    }
  }

  bool _removeIfCurrent(_OriginalExportOperation operation) {
    if (!_isCurrent(operation)) {
      return false;
    }
    _operations.remove(operation.operationId);
    return true;
  }

  static domain.OriginalExportError _mapError(pigeon.OriginalExportErrorCode error) {
    return switch (error) {
      pigeon.OriginalExportErrorCode.assetMissing => domain.OriginalExportError.assetMissing,
      pigeon.OriginalExportErrorCode.mediaNotLocal => domain.OriginalExportError.mediaNotLocal,
      pigeon.OriginalExportErrorCode.iCloudUnavailable => domain.OriginalExportError.iCloudUnavailable,
      pigeon.OriginalExportErrorCode.cancelled => domain.OriginalExportError.cancelled,
      pigeon.OriginalExportErrorCode.staleContext => domain.OriginalExportError.staleContext,
      pigeon.OriginalExportErrorCode.timeout => domain.OriginalExportError.timeout,
      pigeon.OriginalExportErrorCode.unauthorized => domain.OriginalExportError.unauthorized,
      pigeon.OriginalExportErrorCode.wrongServer => domain.OriginalExportError.wrongServer,
      pigeon.OriginalExportErrorCode.serverUnavailable => domain.OriginalExportError.serverUnavailable,
      pigeon.OriginalExportErrorCode.httpFailure => domain.OriginalExportError.httpFailure,
      pigeon.OriginalExportErrorCode.storageUnavailable => domain.OriginalExportError.storageUnavailable,
      pigeon.OriginalExportErrorCode.writeFailed => domain.OriginalExportError.writeFailed,
      pigeon.OriginalExportErrorCode.cleanupFailed => domain.OriginalExportError.cleanupFailed,
      pigeon.OriginalExportErrorCode.leaseNotFound => domain.OriginalExportError.leaseNotFound,
      pigeon.OriginalExportErrorCode.platformUnsupported => domain.OriginalExportError.platformUnsupported,
    };
  }
}

final class _LocalOriginalExportPort implements LocalOriginalExportPort {
  const _LocalOriginalExportPort(this._adapter);

  final NativeOriginalExportAdapter _adapter;

  @override
  CancellableRequest<domain.OriginalExportResult> export(domain.LocalOriginalExportRequest request) {
    return _adapter.exportLocal(request);
  }
}

final class _RemoteOriginalExportPort implements RemoteOriginalExportPort {
  const _RemoteOriginalExportPort(this._adapter);

  final NativeOriginalExportAdapter _adapter;

  @override
  CancellableRequest<domain.OriginalExportResult> export(domain.RemoteOriginalExportRequest request) {
    return _adapter.exportRemote(request);
  }
}

final class _OriginalExportOperation implements CancellableRequest<domain.OriginalExportResult> {
  _OriginalExportOperation(this.operationId, this._cancel) : activeRequestId = operationId;

  final int operationId;
  final Future<void> Function(_OriginalExportOperation operation) _cancel;
  final Completer<domain.OriginalExportResult> _result = Completer();
  int? activeRequestId;
  Future<void>? _cancelFuture;
  bool _terminal = false;
  bool _cancellationRequested = false;

  bool get isCancellationRequested => _cancellationRequested;

  @override
  Future<domain.OriginalExportResult> get result => _result.future;

  bool complete(domain.OriginalExportResult value) {
    if (_terminal) {
      return false;
    }
    _terminal = true;
    _result.complete(value);
    return true;
  }

  bool beginNativeAttempt(int requestId) {
    if (_terminal || _cancellationRequested || activeRequestId != null) {
      return false;
    }
    activeRequestId = requestId;
    return true;
  }

  void finishNativeAttempt(int requestId) {
    if (activeRequestId == requestId) {
      activeRequestId = null;
    }
  }

  void requestCancellation() {
    _cancellationRequested = true;
  }

  @override
  Future<void> cancel() => _cancelFuture ??= _cancel(this);
}
