import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart' as domain;
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/adapters/remote_media/remote_media_host_api.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart' as pigeon;

typedef RemoteMediaPayloadLeaseFactory = RemoteMediaPayloadLease Function(int address, int length);
typedef RemoteNativeBufferReleaser = void Function(int address);

final class NativeRemoteMediaAdapter implements RemoteMediaPort<OwnedRemoteMediaPayload> {
  NativeRemoteMediaAdapter({
    required RemoteMediaHostApi api,
    RemoteMediaPayloadLeaseFactory? leaseFactory,
    RemoteNativeBufferReleaser? releaseNativeBuffer,
  }) : _api = api,
       _leaseFactory = leaseFactory ?? _nativeLease,
       _releaseNativeBuffer = releaseNativeBuffer ?? _releasePointer;

  final RemoteMediaHostApi _api;
  final RemoteMediaPayloadLeaseFactory _leaseFactory;
  final RemoteNativeBufferReleaser _releaseNativeBuffer;
  final Map<int, _RemoteMediaOperation> _operations = {};
  final Set<int> _retiringRequestIds = {};
  final Map<int, Future<void>> _retiringCancellations = {};

  Future<void>? _cancelAllFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;
  bool _cancellingAll = false;

  @override
  CancellableMediaRequest<OwnedRemoteMediaPayload> request(domain.RemoteMediaRequest request) {
    final operation = _RemoteMediaOperation(request.requestId, _cancelRequest);
    if (_disposed ||
        _cancellingAll ||
        _operations.containsKey(request.requestId) ||
        _retiringRequestIds.contains(request.requestId)) {
      operation.complete(const OfflineResult.failure(OfflineErrorCode.mediaUnavailable));
      return operation;
    }

    _operations[request.requestId] = operation;
    unawaited(_dispatch(request, operation));
    return operation;
  }

  @override
  Future<void> cancelAll() {
    final inFlight = _cancelAllFuture;
    if (inFlight != null) {
      return inFlight;
    }
    return _cancelAllFuture = _cancelEveryOperation().whenComplete(() => _cancelAllFuture = null);
  }

  Future<void> dispose() {
    final inFlight = _disposeFuture;
    if (inFlight != null) {
      return inFlight;
    }
    _disposed = true;
    return _disposeFuture = _disposeResources();
  }

  Future<void> _dispatch(domain.RemoteMediaRequest request, _RemoteMediaOperation operation) async {
    try {
      final result = await _api.requestImage(_toPigeonRequest(request));
      _handleResult(operation, request.preferEncoded, result);
    } on Object {
      _completeFailure(operation, OfflineErrorCode.mediaUnavailable);
    }
  }

  Future<void> _cancelRequest(_RemoteMediaOperation operation) async {
    if (!_removeIfCurrent(operation)) {
      return;
    }
    operation.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    final requestId = operation.requestId;
    _retiringRequestIds.add(requestId);
    late final Future<void> cancellation;
    cancellation = _sendNativeCancellation(requestId).whenComplete(() {
      if (identical(_retiringCancellations[requestId], cancellation)) {
        _retiringCancellations.remove(requestId);
        _retiringRequestIds.remove(requestId);
      }
    });
    _retiringCancellations[requestId] = cancellation;
    await cancellation;
  }

  Future<void> _sendNativeCancellation(int requestId) async {
    try {
      await _api.cancelRequest(requestId);
    } on Object {
      return;
    }
  }

  Future<void> _cancelEveryOperation() async {
    _cancellingAll = true;
    final operations = _operations.values.toList(growable: false);
    final retiringCancellations = _retiringCancellations.values.toList(growable: false);
    _operations.clear();
    for (final operation in operations) {
      operation.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    }

    Object? cancellationError;
    StackTrace? cancellationStackTrace;
    try {
      await _api.cancelAll();
    } on Object catch (error, stackTrace) {
      cancellationError = error;
      cancellationStackTrace = stackTrace;
    }
    try {
      await Future.wait(retiringCancellations);
    } finally {
      _cancellingAll = false;
    }
    if (cancellationError != null) {
      Error.throwWithStackTrace(cancellationError, cancellationStackTrace!);
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
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void _handleResult(_RemoteMediaOperation operation, bool preferEncoded, pigeon.RemoteImageResult result) {
    if (!_removeIfCurrent(operation)) {
      _releaseRawPayload(result.payload);
      return;
    }

    final payload = result.payload;
    final error = result.error;
    if ((payload == null) == (error == null)) {
      _releaseRawPayload(payload);
      operation.complete(const OfflineResult.failure(OfflineErrorCode.mediaUnavailable));
      return;
    }
    if (error != null) {
      operation.complete(OfflineResult.failure(_mapError(error)));
      return;
    }

    final OwnedRemoteMediaPayload? ownedPayload;
    try {
      ownedPayload = _takeOwnership(payload!, preferEncoded);
    } on Object {
      _releaseRawPayload(payload);
      operation.complete(const OfflineResult.failure(OfflineErrorCode.mediaUnavailable));
      return;
    }
    if (ownedPayload == null) {
      operation.complete(const OfflineResult.failure(OfflineErrorCode.mediaUnavailable));
      return;
    }
    if (!operation.complete(OfflineResult.success(ownedPayload))) {
      ownedPayload.release();
    }
  }

  OwnedRemoteMediaPayload? _takeOwnership(pigeon.RemoteImagePayload payload, bool preferEncoded) {
    final pointer = payload.pointer;
    if (pointer <= 0) {
      return null;
    }

    final length = payload.length;
    if (length != null) {
      if (length <= 0 || payload.width != null || payload.height != null || payload.rowBytes != null) {
        _releaseNativeBuffer(pointer);
        return null;
      }
      return OwnedEncodedRemoteMediaPayload(lease: _leaseFactory(pointer, length));
    }
    if (preferEncoded) {
      _releaseNativeBuffer(pointer);
      return null;
    }

    final width = payload.width;
    final height = payload.height;
    final rowBytes = payload.rowBytes;
    if (width == null || width <= 0 || height == null || height <= 0 || rowBytes == null || rowBytes < width * 4) {
      _releaseNativeBuffer(pointer);
      return null;
    }
    return OwnedRgbaRemoteMediaPayload(
      lease: _leaseFactory(pointer, rowBytes * height),
      widthPx: width,
      heightPx: height,
      rowBytes: rowBytes,
    );
  }

  void _completeFailure(_RemoteMediaOperation operation, OfflineErrorCode error) {
    if (_removeIfCurrent(operation)) {
      operation.complete(OfflineResult.failure(error));
    }
  }

  bool _removeIfCurrent(_RemoteMediaOperation operation) {
    final current = _operations[operation.requestId];
    if (!identical(current, operation)) {
      return false;
    }
    _operations.remove(operation.requestId);
    return true;
  }

  void _releaseRawPayload(pigeon.RemoteImagePayload? payload) {
    final pointer = payload?.pointer;
    if (pointer != null && pointer > 0) {
      _releaseNativeBuffer(pointer);
    }
  }

  static pigeon.RemoteImageRequest _toPigeonRequest(domain.RemoteMediaRequest request) {
    return pigeon.RemoteImageRequest(
      url: request.resource.toString(),
      origin: request.origin.toString(),
      requestId: request.requestId,
      preferEncoded: request.preferEncoded,
      policy: switch (request.policy) {
        domain.RemoteMediaPolicy.cacheOnly => pigeon.RemoteImagePolicy.cacheOnly,
        domain.RemoteMediaPolicy.cacheThenNetwork => pigeon.RemoteImagePolicy.cacheThenNetwork,
      },
      kind: switch (request.kind) {
        domain.MediaRequestKind.thumbnail => pigeon.RemoteImageRequestKind.thumbnail,
        domain.MediaRequestKind.original => pigeon.RemoteImageRequestKind.original,
      },
    );
  }

  static OfflineErrorCode _mapError(pigeon.RemoteImageErrorCode error) {
    return switch (error) {
      pigeon.RemoteImageErrorCode.cacheMiss => OfflineErrorCode.cacheMiss,
      pigeon.RemoteImageErrorCode.mediaNotLocal => OfflineErrorCode.mediaNotLocal,
      pigeon.RemoteImageErrorCode.iCloudUnavailable => OfflineErrorCode.iCloudUnavailable,
      pigeon.RemoteImageErrorCode.cancelled => OfflineErrorCode.cancelled,
      pigeon.RemoteImageErrorCode.timeout => OfflineErrorCode.timeout,
      pigeon.RemoteImageErrorCode.serverUnavailable => OfflineErrorCode.serverUnavailable,
      pigeon.RemoteImageErrorCode.wrongServer => OfflineErrorCode.wrongServer,
      pigeon.RemoteImageErrorCode.unauthorized => OfflineErrorCode.unauthorized,
    };
  }

  static RemoteMediaPayloadLease _nativeLease(int address, int length) {
    return _MallocRemoteMediaPayloadLease(address: address, length: length);
  }

  static void _releasePointer(int address) {
    malloc.free(Pointer<Uint8>.fromAddress(address));
  }
}

final class _RemoteMediaOperation implements CancellableMediaRequest<OwnedRemoteMediaPayload> {
  _RemoteMediaOperation(this.requestId, this._cancel);

  final int requestId;
  final Future<void> Function(_RemoteMediaOperation operation) _cancel;
  final Completer<OfflineResult<OwnedRemoteMediaPayload>> _result = Completer();
  Future<void>? _cancelFuture;
  bool _terminal = false;

  @override
  Future<OfflineResult<OwnedRemoteMediaPayload>> get result => _result.future;

  @override
  Stream<domain.MediaRequestProgress> get progress => const Stream.empty();

  bool complete(OfflineResult<OwnedRemoteMediaPayload> value) {
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

final class _MallocRemoteMediaPayloadLease implements RemoteMediaPayloadLease {
  _MallocRemoteMediaPayloadLease({required int address, required int length})
    : _pointer = Pointer<Uint8>.fromAddress(address),
      _length = length;

  final Pointer<Uint8> _pointer;
  final int _length;
  bool _released = false;

  @override
  Uint8List get bytes {
    if (_released) {
      throw StateError('Remote media payload was already released');
    }
    return _pointer.asTypedList(_length);
  }

  @override
  bool get isReleased => _released;

  @override
  void release() {
    if (_released) {
      return;
    }
    _released = true;
    malloc.free(_pointer);
  }
}
