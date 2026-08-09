import 'dart:async';
import 'dart:ffi';
import 'dart:typed_data';

import 'package:ffi/ffi.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart' as domain;
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/local_media_host_api.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart' as pigeon;

typedef LocalMediaFlutterApiRegistration = void Function(pigeon.LocalImageFlutterApi? api);
typedef LocalMediaPayloadLeaseFactory = LocalMediaPayloadLease Function(int address, int length);
typedef NativeBufferReleaser = void Function(int address);

final class NativeLocalMediaAdapter implements LocalMediaPort<OwnedLocalMediaPayload>, pigeon.LocalImageFlutterApi {
  NativeLocalMediaAdapter({
    required LocalMediaHostApi api,
    required TransportAvailability Function() readTransportAvailability,
    LocalMediaFlutterApiRegistration? registerFlutterApi,
    LocalMediaPayloadLeaseFactory? leaseFactory,
    NativeBufferReleaser? releaseNativeBuffer,
  }) : _api = api,
       _readTransportAvailability = readTransportAvailability,
       _registerFlutterApi = registerFlutterApi ?? _registerWithPigeon,
       _leaseFactory = leaseFactory ?? _nativeLease,
       _releaseNativeBuffer = releaseNativeBuffer ?? _releasePointer {
    _registerFlutterApi(this);
  }

  final LocalMediaHostApi _api;
  final TransportAvailability Function() _readTransportAvailability;
  final LocalMediaFlutterApiRegistration _registerFlutterApi;
  final LocalMediaPayloadLeaseFactory _leaseFactory;
  final NativeBufferReleaser _releaseNativeBuffer;
  final Map<int, _LocalMediaOperation> _operations = {};
  final Set<int> _retiringRequestIds = {};
  final Map<int, Future<void>> _retiringCancellations = {};

  Future<void>? _cancelAllFuture;
  Future<void>? _disposeFuture;
  bool _disposed = false;
  bool _cancellingAll = false;
  bool _flutterApiRegistered = true;

  @override
  CancellableMediaRequest<OwnedLocalMediaPayload> request(domain.LocalMediaRequest request) {
    final operation = _LocalMediaOperation(request.requestId, _cancelRequest);
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
  void onProgress(pigeon.LocalImageProgress progress) {
    final operation = _operations[progress.requestId];
    if (operation == null) {
      return;
    }
    try {
      operation.addProgress(domain.MediaRequestProgress(requestId: progress.requestId, fraction: progress.fraction));
    } on ArgumentError {
      return;
    }
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

  Future<void> _dispatch(domain.LocalMediaRequest request, _LocalMediaOperation operation) async {
    try {
      final result = await _api.requestImage(_toPigeonRequest(request));
      _handleResult(operation, request.rendition, result);
    } on Object {
      _completeFailure(operation, OfflineErrorCode.mediaUnavailable);
    }
  }

  Future<void> _cancelRequest(_LocalMediaOperation operation) async {
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

  void _handleResult(
    _LocalMediaOperation operation,
    domain.LocalMediaRendition rendition,
    pigeon.LocalImageResult result,
  ) {
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

    final OwnedLocalMediaPayload? ownedPayload;
    try {
      ownedPayload = _takeOwnership(payload!, rendition);
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

  OwnedLocalMediaPayload? _takeOwnership(pigeon.LocalImagePayload payload, domain.LocalMediaRendition rendition) {
    final pointer = payload.pointer;
    if (pointer <= 0) {
      return null;
    }
    switch (rendition) {
      case domain.LocalMediaThumbnailRendition():
        final width = payload.width;
        final height = payload.height;
        final rowBytes = payload.rowBytes;
        if (payload.length != null ||
            width == null ||
            width <= 0 ||
            height == null ||
            height <= 0 ||
            rowBytes == null ||
            rowBytes < width * 4) {
          _releaseNativeBuffer(pointer);
          return null;
        }
        return OwnedRgbaLocalMediaPayload(
          lease: _leaseFactory(pointer, rowBytes * height),
          widthPx: width,
          heightPx: height,
          rowBytes: rowBytes,
        );
      case domain.LocalMediaOriginalEncodedRendition():
        final length = payload.length;
        if (length == null ||
            length <= 0 ||
            payload.width != null ||
            payload.height != null ||
            payload.rowBytes != null) {
          _releaseNativeBuffer(pointer);
          return null;
        }
        return OwnedEncodedLocalMediaPayload(lease: _leaseFactory(pointer, length));
    }
  }

  void _completeFailure(_LocalMediaOperation operation, OfflineErrorCode error) {
    if (_removeIfCurrent(operation)) {
      operation.complete(OfflineResult.failure(error));
    }
  }

  bool _removeIfCurrent(_LocalMediaOperation operation) {
    final current = _operations[operation.requestId];
    if (!identical(current, operation)) {
      return false;
    }
    _operations.remove(operation.requestId);
    return true;
  }

  void _releaseRawPayload(pigeon.LocalImagePayload? payload) {
    final pointer = payload?.pointer;
    if (pointer != null && pointer > 0) {
      _releaseNativeBuffer(pointer);
    }
  }

  pigeon.LocalImageRequest _toPigeonRequest(domain.LocalMediaRequest request) {
    final policy =
        request.policy == domain.LocalMediaPolicy.allowICloud &&
            _readTransportAvailability() == TransportAvailability.available
        ? pigeon.LocalImagePolicy.allowICloud
        : pigeon.LocalImagePolicy.localOnly;
    final (width, height, preferEncoded, kind) = switch (request.rendition) {
      domain.LocalMediaThumbnailRendition(:final widthPx, :final heightPx) => (
        widthPx,
        heightPx,
        false,
        pigeon.LocalImageRequestKind.thumbnail,
      ),
      domain.LocalMediaOriginalEncodedRendition() => (0, 0, true, pigeon.LocalImageRequestKind.original),
    };
    return pigeon.LocalImageRequest(
      assetId: request.assetId,
      requestId: request.requestId,
      width: width,
      height: height,
      isVideo: request.assetType == AssetType.video,
      preferEncoded: preferEncoded,
      policy: policy,
      kind: kind,
    );
  }

  static OfflineErrorCode _mapError(pigeon.LocalImageErrorCode error) {
    return switch (error) {
      pigeon.LocalImageErrorCode.mediaNotLocal ||
      pigeon.LocalImageErrorCode.cacheMiss => OfflineErrorCode.mediaNotLocal,
      pigeon.LocalImageErrorCode.iCloudUnavailable => OfflineErrorCode.iCloudUnavailable,
      pigeon.LocalImageErrorCode.cancelled => OfflineErrorCode.cancelled,
      pigeon.LocalImageErrorCode.timeout => OfflineErrorCode.timeout,
      pigeon.LocalImageErrorCode.serverUnavailable ||
      pigeon.LocalImageErrorCode.wrongServer ||
      pigeon.LocalImageErrorCode.unauthorized => OfflineErrorCode.mediaUnavailable,
    };
  }

  static void _registerWithPigeon(pigeon.LocalImageFlutterApi? api) {
    pigeon.LocalImageFlutterApi.setUp(api);
  }

  static LocalMediaPayloadLease _nativeLease(int address, int length) {
    return _MallocLocalMediaPayloadLease(address: address, length: length);
  }

  static void _releasePointer(int address) {
    malloc.free(Pointer<Uint8>.fromAddress(address));
  }
}

final class _LocalMediaOperation implements CancellableMediaRequest<OwnedLocalMediaPayload> {
  _LocalMediaOperation(this.requestId, this._cancel);

  final int requestId;
  final Future<void> Function(_LocalMediaOperation operation) _cancel;
  final Completer<OfflineResult<OwnedLocalMediaPayload>> _result = Completer();
  final StreamController<domain.MediaRequestProgress> _progress = StreamController.broadcast(sync: true);
  Future<void>? _cancelFuture;
  bool _terminal = false;

  @override
  Future<OfflineResult<OwnedLocalMediaPayload>> get result => _result.future;

  @override
  Stream<domain.MediaRequestProgress> get progress => _progress.stream;

  void addProgress(domain.MediaRequestProgress value) {
    if (!_terminal) {
      _progress.add(value);
    }
  }

  bool complete(OfflineResult<OwnedLocalMediaPayload> value) {
    if (_terminal) {
      return false;
    }
    _terminal = true;
    _result.complete(value);
    unawaited(_progress.close());
    return true;
  }

  @override
  Future<void> cancel() => _cancelFuture ??= _cancel(this);
}

final class _MallocLocalMediaPayloadLease implements LocalMediaPayloadLease {
  _MallocLocalMediaPayloadLease({required int address, required int length})
    : _pointer = Pointer<Uint8>.fromAddress(address),
      _length = length;

  final Pointer<Uint8> _pointer;
  final int _length;
  bool _released = false;

  @override
  Uint8List get bytes {
    if (_released) {
      throw StateError('Local media payload was already released');
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
