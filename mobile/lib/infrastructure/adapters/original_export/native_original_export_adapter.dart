import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart' as domain;
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/original_export_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/owned_temporary_file_lease.dart';
import 'package:immich_mobile/platform/original_export_api.g.dart' as pigeon;

typedef TemporaryFileLeaseFactory =
    Future<TemporaryFileLease> Function(String path, String leaseToken, NativeLeaseReleaser releaseNativeLease);
typedef OriginalExportFlutterApiRegistration = void Function(pigeon.OriginalExportFlutterApi? api);

final class OriginalExportSessionSnapshot {
  const OriginalExportSessionSnapshot({required this.reachability, required this.sessionActive});

  final ReachabilityState reachability;
  final bool sessionActive;

  bool authorizes(Uri resource) {
    final endpoint = reachability.confirmedEndpoint;
    if (!sessionActive || reachability.phase != ReachabilityPhase.online || endpoint == null) {
      return false;
    }
    if (_origin(resource) != _origin(endpoint)) {
      return false;
    }
    final endpointPath = endpoint.path.endsWith('/') ? endpoint.path : '${endpoint.path}/';
    return resource.path.startsWith(endpointPath);
  }

  static Uri _origin(Uri uri) => Uri(scheme: uri.scheme, host: uri.host, port: uri.hasPort ? uri.port : null);
}

final class NativeOriginalExportAdapter implements pigeon.OriginalExportFlutterApi {
  NativeOriginalExportAdapter({
    required OriginalExportHostApi api,
    required TransportAvailability Function() readTransportAvailability,
    required OriginalExportSessionSnapshot Function() readSessionSnapshot,
    required TemporaryFileLeaseFactory leaseFactory,
    OriginalExportFlutterApiRegistration? registerFlutterApi,
  }) : _api = api,
       _readTransportAvailability = readTransportAvailability,
       _readSessionSnapshot = readSessionSnapshot,
       _leaseFactory = leaseFactory,
       _registerFlutterApi = registerFlutterApi ?? pigeon.OriginalExportFlutterApi.setUp {
    _registerFlutterApi(this);
  }

  final OriginalExportHostApi _api;
  final TransportAvailability Function() _readTransportAvailability;
  final OriginalExportSessionSnapshot Function() _readSessionSnapshot;
  final TemporaryFileLeaseFactory _leaseFactory;
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
    if (!_readSessionSnapshot().authorizes(request.resource)) {
      _operations.remove(operation.requestId);
      operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.serverUnavailable));
      return operation;
    }
    unawaited(_dispatchRemote(request, operation));
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
    while (_operations.containsKey(_nextRequestId) || _retiringRequestIds.contains(_nextRequestId)) {
      _nextRequestId++;
    }
    return _OriginalExportOperation(_nextRequestId++, _cancelRequest);
  }

  bool _accept(_OriginalExportOperation operation) {
    if (_disposed || _cancellingAll) {
      operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.cancelled));
      return false;
    }
    _operations[operation.requestId] = operation;
    return true;
  }

  Future<void> _dispatchLocal(domain.LocalOriginalExportRequest request, _OriginalExportOperation operation) async {
    final policy =
        request.policy == domain.LocalOriginalExportPolicy.allowICloud &&
            _readTransportAvailability() == TransportAvailability.available
        ? pigeon.OriginalExportPolicy.allowICloud
        : pigeon.OriginalExportPolicy.localOnly;
    try {
      final result = await _api.exportLocal(
        pigeon.LocalOriginalExportRequest(
          requestId: operation.requestId,
          assetId: request.assetId,
          suggestedName: request.suggestedFilename,
          policy: policy,
        ),
      );
      await _handleResult(operation, result);
    } on Object {
      _completeFailure(operation, domain.OriginalExportError.storageUnavailable);
    }
  }

  Future<void> _dispatchRemote(domain.RemoteOriginalExportRequest request, _OriginalExportOperation operation) async {
    try {
      final result = await _api.exportRemote(
        pigeon.RemoteOriginalExportRequest(
          requestId: operation.requestId,
          url: request.resource.toString(),
          origin: request.origin.toString(),
          suggestedName: request.suggestedFilename,
        ),
      );
      await _handleResult(operation, result);
    } on Object {
      _completeFailure(operation, domain.OriginalExportError.serverUnavailable);
    }
  }

  Future<void> _handleResult(_OriginalExportOperation operation, pigeon.OriginalExportResult result) async {
    final path = result.path;
    final leaseToken = result.leaseToken;
    final error = result.error;
    final isFailure = path == null && leaseToken == null && error != null;
    final isSuccess =
        path != null && path.trim().isNotEmpty && leaseToken != null && leaseToken.trim().isNotEmpty && error == null;
    if (!isFailure && !isSuccess) {
      await _releaseReturnedToken(leaseToken);
      if (_removeIfCurrent(operation)) {
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
        operation.complete(const domain.OriginalExportResult.failure(domain.OriginalExportError.storageUnavailable));
      }
      return;
    }
    if (!_removeIfCurrent(operation) || !operation.complete(domain.OriginalExportResult.success(lease))) {
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
    if (!identical(_operations[operation.requestId], operation)) {
      return;
    }
    final requestId = operation.requestId;
    _retiringRequestIds.add(requestId);
    late final Future<void> cancellation;
    cancellation = _cancelAndAwaitTerminal(operation).whenComplete(() {
      if (identical(_retiringCancellations[requestId], cancellation)) {
        _retiringCancellations.remove(requestId);
        _retiringRequestIds.remove(requestId);
      }
    });
    _retiringCancellations[requestId] = cancellation;
    await cancellation;
  }

  Future<void> _cancelAndAwaitTerminal(_OriginalExportOperation operation) async {
    await _api.cancelRequest(operation.requestId);
    await operation.result;
  }

  Future<void> _cancelEveryOperation() async {
    _cancellingAll = true;
    final operations = _operations.values.toList(growable: false);
    final retiring = _retiringCancellations.values.toList(growable: false);
    for (final operation in operations) {
      _retiringRequestIds.add(operation.requestId);
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
      for (final operation in operations) {
        if (!_retiringCancellations.containsKey(operation.requestId)) {
          _retiringRequestIds.remove(operation.requestId);
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
    if (!identical(_operations[operation.requestId], operation)) {
      return false;
    }
    _operations.remove(operation.requestId);
    return true;
  }

  static domain.OriginalExportError _mapError(pigeon.OriginalExportErrorCode error) {
    return switch (error) {
      pigeon.OriginalExportErrorCode.assetMissing => domain.OriginalExportError.assetMissing,
      pigeon.OriginalExportErrorCode.mediaNotLocal => domain.OriginalExportError.mediaNotLocal,
      pigeon.OriginalExportErrorCode.iCloudUnavailable => domain.OriginalExportError.iCloudUnavailable,
      pigeon.OriginalExportErrorCode.cancelled => domain.OriginalExportError.cancelled,
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
  _OriginalExportOperation(this.requestId, this._cancel);

  final int requestId;
  final Future<void> Function(_OriginalExportOperation operation) _cancel;
  final Completer<domain.OriginalExportResult> _result = Completer();
  Future<void>? _cancelFuture;
  bool _terminal = false;

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

  @override
  Future<void> cancel() => _cancelFuture ??= _cancel(this);
}
