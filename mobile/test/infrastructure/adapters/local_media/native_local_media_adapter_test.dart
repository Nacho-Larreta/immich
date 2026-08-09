import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart' as domain;
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/local_media_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/native_local_media_adapter.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart' as pigeon;

void main() {
  group('NativeLocalMediaAdapter', () {
    for (final requested in domain.LocalMediaPolicy.values) {
      for (final availability in TransportAvailability.values) {
        test('maps $requested with $availability transport', () async {
          final harness = _Harness(availability: availability);
          final operation = harness.adapter.request(_thumbnailRequest(policy: requested));

          final nativeRequest = harness.host.requests.single;
          final expected =
              requested == domain.LocalMediaPolicy.allowICloud && availability == TransportAvailability.available
              ? pigeon.LocalImagePolicy.allowICloud
              : pigeon.LocalImagePolicy.localOnly;
          expect(nativeRequest.policy, expected);
          expect(nativeRequest.width, 320);
          expect(nativeRequest.height, 180);
          expect(nativeRequest.preferEncoded, isFalse);
          expect(nativeRequest.kind, pigeon.LocalImageRequestKind.thumbnail);

          harness.host.completeSuccess(
            nativeRequest.requestId,
            pigeon.LocalImagePayload(pointer: 1, width: 320, height: 180, rowBytes: 1280),
          );
          final result = await operation.result;
          result.valueOrNull?.release();
          await harness.adapter.dispose();
        });
      }
    }

    test('maps original encoded rendition and video identity without domain sentinels', () async {
      final harness = _Harness(availability: TransportAvailability.available);
      final operation = harness.adapter.request(
        domain.LocalMediaRequest(
          requestId: 8,
          assetId: 'video-1',
          assetType: AssetType.video,
          policy: domain.LocalMediaPolicy.allowICloud,
          rendition: const domain.LocalMediaRendition.originalEncoded(),
        ),
      );

      final request = harness.host.requests.single;
      expect(request.isVideo, isTrue);
      expect(request.width, 0);
      expect(request.height, 0);
      expect(request.preferEncoded, isTrue);
      expect(request.kind, pigeon.LocalImageRequestKind.original);
      harness.host.completeSuccess(request.requestId, pigeon.LocalImagePayload(pointer: 2, length: 12));
      final result = await operation.result;
      result.valueOrNull?.release();
      await harness.adapter.dispose();
    });

    test('reads transport availability live without recreating the adapter', () async {
      final harness = _Harness(availability: TransportAvailability.unavailable);
      final offline = harness.adapter.request(_thumbnailRequest(policy: domain.LocalMediaPolicy.allowICloud));
      expect(harness.host.requests.single.policy, pigeon.LocalImagePolicy.localOnly);
      harness.host.completeError(1, pigeon.LocalImageErrorCode.mediaNotLocal);
      await offline.result;

      harness.availability = TransportAvailability.available;
      final online = harness.adapter.request(
        _thumbnailRequest(requestId: 2, policy: domain.LocalMediaPolicy.allowICloud),
      );
      expect(harness.host.requests.last.policy, pigeon.LocalImagePolicy.allowICloud);
      harness.host.completeError(2, pigeon.LocalImageErrorCode.iCloudUnavailable);
      await online.result;
      await harness.adapter.dispose();
    });

    for (final mapping in <(pigeon.LocalImageErrorCode, OfflineErrorCode)>[
      (pigeon.LocalImageErrorCode.mediaNotLocal, OfflineErrorCode.mediaNotLocal),
      (pigeon.LocalImageErrorCode.iCloudUnavailable, OfflineErrorCode.iCloudUnavailable),
      (pigeon.LocalImageErrorCode.cancelled, OfflineErrorCode.cancelled),
      (pigeon.LocalImageErrorCode.timeout, OfflineErrorCode.timeout),
      (pigeon.LocalImageErrorCode.cacheMiss, OfflineErrorCode.mediaNotLocal),
      (pigeon.LocalImageErrorCode.serverUnavailable, OfflineErrorCode.mediaUnavailable),
      (pigeon.LocalImageErrorCode.wrongServer, OfflineErrorCode.mediaUnavailable),
      (pigeon.LocalImageErrorCode.unauthorized, OfflineErrorCode.mediaUnavailable),
    ]) {
      test('maps ${mapping.$1.name} without leaking platform details', () async {
        final harness = _Harness();
        final operation = harness.adapter.request(_thumbnailRequest());
        harness.host.completeError(1, mapping.$1);

        expect(await operation.result, OfflineResult<OwnedLocalMediaPayload>.failure(mapping.$2));
        await harness.adapter.dispose();
      });
    }

    test('maps channel and malformed XOR results to mediaUnavailable', () async {
      final channelHarness = _Harness();
      final channelOperation = channelHarness.adapter.request(_thumbnailRequest());
      channelHarness.host.completeFailure(1, StateError('channel failed'));
      expect(
        await channelOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      await channelHarness.adapter.dispose();

      final malformedHarness = _Harness();
      final malformedOperation = malformedHarness.adapter.request(_thumbnailRequest());
      malformedHarness.host.complete(
        1,
        pigeon.LocalImageResult(
          payload: pigeon.LocalImagePayload(pointer: 11, width: 1, height: 1, rowBytes: 4),
          error: pigeon.LocalImageErrorCode.timeout,
        ),
      );
      expect(
        await malformedOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      expect(malformedHarness.releasedAddresses, [11]);
      await malformedHarness.adapter.dispose();

      final emptyHarness = _Harness();
      final emptyOperation = emptyHarness.adapter.request(_thumbnailRequest());
      emptyHarness.host.complete(1, pigeon.LocalImageResult());
      expect(
        await emptyOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      await emptyHarness.adapter.dispose();
    });

    test('isolates progress by requestId and closes it after one terminal result', () async {
      final harness = _Harness();
      final first = harness.adapter.request(_thumbnailRequest());
      final second = harness.adapter.request(_thumbnailRequest(requestId: 2));
      final firstProgress = <double>[];
      final secondProgress = <double>[];
      first.progress.listen((event) => firstProgress.add(event.fraction));
      second.progress.listen((event) => secondProgress.add(event.fraction));

      harness.registration.activeApi!.onProgress(pigeon.LocalImageProgress(requestId: 1, fraction: 0.25));
      harness.registration.activeApi!.onProgress(pigeon.LocalImageProgress(requestId: 2, fraction: 0.75));
      harness.registration.activeApi!.onProgress(pigeon.LocalImageProgress(requestId: 404, fraction: 0.5));
      harness.host.completeError(1, pigeon.LocalImageErrorCode.timeout);
      await first.result;
      harness.registration.activeApi!.onProgress(pigeon.LocalImageProgress(requestId: 1, fraction: 0.9));

      expect(firstProgress, [0.25]);
      expect(secondProgress, [0.75]);
      await second.cancel();
      await harness.adapter.dispose();
    });

    test('individual cancel is idempotent and releases a late success exactly once', () async {
      final harness = _Harness();
      final operation = harness.adapter.request(_thumbnailRequest());

      final firstCancel = operation.cancel();
      final secondCancel = operation.cancel();
      expect(identical(firstCancel, secondCancel), isTrue);
      await Future.wait([firstCancel, secondCancel]);
      expect(harness.host.cancelledRequestIds, [1]);
      expect(await operation.result, const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.cancelled));

      harness.host.completeSuccess(1, pigeon.LocalImagePayload(pointer: 21, width: 1, height: 1, rowBytes: 4));
      await pumpEventQueue();
      expect(harness.releasedAddresses, [21]);
      await harness.adapter.dispose();
    });

    test('duplicate rejection cancel is a no-op for the original operation', () async {
      final harness = _Harness();
      final original = harness.adapter.request(_thumbnailRequest());
      final duplicate = harness.adapter.request(_thumbnailRequest());

      expect(
        await duplicate.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      await duplicate.cancel();
      expect(harness.host.cancelledRequestIds, isEmpty);

      harness.host.completeError(1, pigeon.LocalImageErrorCode.timeout);
      expect(await original.result, const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.timeout));
      await harness.adapter.dispose();
    });

    test('late success from a cancelled operation cannot complete a reused requestId', () async {
      final harness = _Harness();
      final oldOperation = harness.adapter.request(_thumbnailRequest());
      await oldOperation.cancel();
      final currentOperation = harness.adapter.request(_thumbnailRequest());
      var currentCompleted = false;
      unawaited(currentOperation.result.then((_) => currentCompleted = true));

      harness.host.completeCall(
        0,
        pigeon.LocalImageResult(payload: pigeon.LocalImagePayload(pointer: 51, width: 1, height: 1, rowBytes: 4)),
      );
      await pumpEventQueue();
      expect(currentCompleted, isFalse);
      expect(harness.releasedAddresses, [51]);

      harness.host.completeCall(1, pigeon.LocalImageResult(error: pigeon.LocalImageErrorCode.timeout));
      expect(
        await currentOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.timeout),
      );
      await harness.adapter.dispose();
    });

    test('late failure from a cancelled operation cannot complete a reused requestId', () async {
      final harness = _Harness();
      final oldOperation = harness.adapter.request(_thumbnailRequest());
      await oldOperation.cancel();
      final currentOperation = harness.adapter.request(_thumbnailRequest());
      var currentCompleted = false;
      unawaited(currentOperation.result.then((_) => currentCompleted = true));

      harness.host.completeCallFailure(0, StateError('late channel failure'));
      await pumpEventQueue();
      expect(currentCompleted, isFalse);

      harness.host.completeCall(1, pigeon.LocalImageResult(error: pigeon.LocalImageErrorCode.mediaNotLocal));
      expect(
        await currentOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaNotLocal),
      );
      await harness.adapter.dispose();
    });

    test('cancel on an old terminal handle cannot cancel a reused requestId', () async {
      final harness = _Harness();
      final oldOperation = harness.adapter.request(_thumbnailRequest());
      harness.host.completeError(1, pigeon.LocalImageErrorCode.timeout);
      await oldOperation.result;
      final currentOperation = harness.adapter.request(_thumbnailRequest());

      await oldOperation.cancel();
      expect(harness.host.cancelledRequestIds, isEmpty);
      harness.host.completeError(1, pigeon.LocalImageErrorCode.mediaNotLocal);
      expect(
        await currentOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaNotLocal),
      );
      await harness.adapter.dispose();
    });

    test('native cancel failure is consumed after local terminal cancellation', () async {
      final harness = _Harness(cancelRequestError: StateError('channel failed'));
      final operation = harness.adapter.request(_thumbnailRequest());

      await expectLater(operation.cancel(), completes);
      expect(await operation.result, const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.cancelled));
      expect(harness.host.cancelledRequestIds, [1]);
      harness.host.completeError(1, pigeon.LocalImageErrorCode.cancelled);
      await pumpEventQueue();
      await harness.adapter.dispose();
    });

    test('keeps a cancelled requestId retired until native cancellation acknowledges', () async {
      final cancelAck = Completer<void>();
      final harness = _Harness(cancelRequest: cancelAck.future);
      final retiredOperation = harness.adapter.request(_thumbnailRequest());

      final cancellation = retiredOperation.cancel();
      await pumpEventQueue();
      expect(harness.host.cancelledRequestIds, [1]);
      expect(
        await retiredOperation.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.cancelled),
      );

      final rejectedReuse = harness.adapter.request(_thumbnailRequest());
      expect(
        await rejectedReuse.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      await rejectedReuse.cancel();
      expect(harness.host.cancelledRequestIds, [1]);
      expect(harness.host.requests, hasLength(1));

      cancelAck.complete();
      await cancellation;
      final acceptedReuse = harness.adapter.request(_thumbnailRequest());
      expect(harness.host.requests, hasLength(2));

      harness.host.completeCall(0, pigeon.LocalImageResult(error: pigeon.LocalImageErrorCode.cancelled));
      await pumpEventQueue();
      harness.host.completeCall(1, pigeon.LocalImageResult(error: pigeon.LocalImageErrorCode.timeout));
      expect(await acceptedReuse.result, const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.timeout));
      await harness.adapter.dispose();
    });

    test('cancelAll waits for individual cancellations already retiring', () async {
      final cancelAck = Completer<void>();
      final harness = _Harness(cancelRequest: cancelAck.future);
      final operation = harness.adapter.request(_thumbnailRequest());

      final individualCancellation = operation.cancel();
      await pumpEventQueue();
      final allCancellation = harness.adapter.cancelAll();
      var returned = false;
      unawaited(allCancellation.then((_) => returned = true));
      await pumpEventQueue();
      expect(returned, isFalse);

      cancelAck.complete();
      await Future.wait([individualCancellation, allCancellation]);
      expect(returned, isTrue);
      harness.host.completeError(1, pigeon.LocalImageErrorCode.cancelled);
      await pumpEventQueue();
      await harness.adapter.dispose();
    });

    test('cancelAll waits for native ack, empties the registry, and permits later login work', () async {
      final cancelAck = Completer<void>();
      final harness = _Harness(cancelAll: cancelAck.future);
      final first = harness.adapter.request(_thumbnailRequest());
      final second = harness.adapter.request(_thumbnailRequest(requestId: 2));

      final cancellation = harness.adapter.cancelAll();
      var returned = false;
      unawaited(cancellation.then((_) => returned = true));
      await pumpEventQueue();
      expect(returned, isFalse);
      expect(await first.result, const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.cancelled));
      expect(await second.result, const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.cancelled));
      harness.host.completeSuccess(1, pigeon.LocalImagePayload(pointer: 41, width: 1, height: 1, rowBytes: 4));
      harness.host.completeSuccess(2, pigeon.LocalImagePayload(pointer: 42, width: 1, height: 1, rowBytes: 4));
      await pumpEventQueue();
      expect(harness.releasedAddresses, [41, 42]);

      final duringLogout = harness.adapter.request(_thumbnailRequest(requestId: 3));
      expect(
        await duringLogout.result,
        const OfflineResult<OwnedLocalMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      cancelAck.complete();
      await cancellation;

      final afterLogin = harness.adapter.request(_thumbnailRequest(requestId: 4));
      expect(harness.host.requests.last.requestId, 4);
      await afterLogin.cancel();
      await harness.adapter.dispose();
    });

    test('transfers a valid lease and makes release idempotent', () async {
      final harness = _Harness();
      final operation = harness.adapter.request(_thumbnailRequest());
      harness.host.completeSuccess(1, pigeon.LocalImagePayload(pointer: 31, width: 1, height: 1, rowBytes: 4));

      final payload = (await operation.result).valueOrNull! as OwnedRgbaLocalMediaPayload;
      final lease = harness.leases.single;
      expect(payload.bytes, hasLength(4));
      payload.release();
      payload.release();
      expect(lease.releaseCount, 1);
      await harness.adapter.dispose();
    });

    test('registers once and unregisters only on idempotent dispose', () async {
      final harness = _Harness();
      expect(harness.registration.calls, [harness.adapter]);

      await harness.adapter.cancelAll();
      expect(harness.registration.calls, [harness.adapter]);
      final first = harness.adapter.dispose();
      final second = harness.adapter.dispose();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);

      expect(harness.registration.calls, [harness.adapter, null]);
      expect(harness.host.disposeCount, 1);
    });

    test('explicit dispose propagates the first native lifecycle failure after cleanup', () async {
      final error = StateError('channel failed');
      final harness = _Harness(cancelAllError: error, disposeError: StateError('dispose failed'));

      await expectLater(harness.adapter.dispose(), throwsA(same(error)));
      expect(harness.registration.calls, [harness.adapter, null]);
      expect(harness.host.disposeCount, 1);
    });
  });
}

domain.LocalMediaRequest _thumbnailRequest({
  int requestId = 1,
  domain.LocalMediaPolicy policy = domain.LocalMediaPolicy.localOnly,
}) {
  return domain.LocalMediaRequest(
    requestId: requestId,
    assetId: 'asset-$requestId',
    assetType: AssetType.image,
    policy: policy,
    rendition: domain.LocalMediaRendition.thumbnail(widthPx: 320, heightPx: 180),
  );
}

final class _Harness {
  _Harness({
    this.availability = TransportAvailability.unknown,
    Future<void>? cancelAll,
    Future<void>? cancelRequest,
    Object? cancelAllError,
    Object? cancelRequestError,
    Object? disposeError,
  }) : host = _FakeLocalMediaHostApi(
         cancelAll: cancelAll,
         cancelRequest: cancelRequest,
         cancelAllError: cancelAllError,
         cancelRequestError: cancelRequestError,
         disposeError: disposeError,
       ) {
    adapter = NativeLocalMediaAdapter(
      api: host,
      readTransportAvailability: () => availability,
      registerFlutterApi: registration.call,
      leaseFactory: (address, length) {
        final lease = _FakeLease(length);
        leases.add(lease);
        return lease;
      },
      releaseNativeBuffer: releasedAddresses.add,
    );
  }

  final _FakeLocalMediaHostApi host;
  TransportAvailability availability;
  final _FakeRegistration registration = _FakeRegistration();
  final List<_FakeLease> leases = [];
  final List<int> releasedAddresses = [];
  late final NativeLocalMediaAdapter adapter;
}

final class _FakeLocalMediaHostApi implements LocalMediaHostApi {
  _FakeLocalMediaHostApi({
    Future<void>? cancelAll,
    Future<void>? cancelRequest,
    this.cancelAllError,
    this.cancelRequestError,
    this.disposeError,
  }) : _cancelAll = cancelAll ?? Future.value(),
       _cancelRequest = cancelRequest ?? Future.value();

  final Future<void> _cancelAll;
  final Future<void> _cancelRequest;
  final Object? cancelAllError;
  final Object? cancelRequestError;
  final Object? disposeError;
  final List<pigeon.LocalImageRequest> requests = [];
  final List<int> cancelledRequestIds = [];
  final List<_HostRequestCall> calls = [];
  int disposeCount = 0;

  @override
  Future<pigeon.LocalImageResult> requestImage(pigeon.LocalImageRequest request) {
    requests.add(request);
    final result = Completer<pigeon.LocalImageResult>();
    calls.add(_HostRequestCall(request, result));
    return result.future;
  }

  void complete(int requestId, pigeon.LocalImageResult result) {
    _pendingCall(requestId).result.complete(result);
  }

  void completeCall(int index, pigeon.LocalImageResult result) => calls[index].result.complete(result);

  void completeSuccess(int requestId, pigeon.LocalImagePayload payload) {
    complete(requestId, pigeon.LocalImageResult(payload: payload));
  }

  void completeError(int requestId, pigeon.LocalImageErrorCode error) {
    complete(requestId, pigeon.LocalImageResult(error: error));
  }

  void completeFailure(int requestId, Object error) => _pendingCall(requestId).result.completeError(error);

  void completeCallFailure(int index, Object error) => calls[index].result.completeError(error);

  @override
  Future<void> cancelRequest(int requestId) async {
    cancelledRequestIds.add(requestId);
    await _cancelRequest;
    final error = cancelRequestError;
    if (error != null) {
      throw error;
    }
  }

  @override
  Future<void> cancelAll() async {
    final error = cancelAllError;
    if (error != null) {
      throw error;
    }
    await _cancelAll;
  }

  @override
  Future<void> dispose() async {
    disposeCount++;
    final error = disposeError;
    if (error != null) {
      throw error;
    }
  }

  _HostRequestCall _pendingCall(int requestId) {
    return calls.firstWhere((call) => call.request.requestId == requestId && !call.result.isCompleted);
  }
}

final class _HostRequestCall {
  const _HostRequestCall(this.request, this.result);

  final pigeon.LocalImageRequest request;
  final Completer<pigeon.LocalImageResult> result;
}

final class _FakeRegistration {
  final List<pigeon.LocalImageFlutterApi?> calls = [];
  pigeon.LocalImageFlutterApi? activeApi;

  void call(pigeon.LocalImageFlutterApi? api) {
    calls.add(api);
    activeApi = api;
  }
}

final class _FakeLease implements LocalMediaPayloadLease {
  _FakeLease(int length) : _bytes = Uint8List(length);

  final Uint8List _bytes;
  int releaseCount = 0;

  @override
  Uint8List get bytes {
    if (isReleased) {
      throw StateError('released');
    }
    return _bytes;
  }

  @override
  bool get isReleased => releaseCount > 0;

  @override
  void release() {
    if (!isReleased) {
      releaseCount++;
    }
  }
}
