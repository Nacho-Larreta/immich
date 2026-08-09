import 'dart:async';
import 'dart:typed_data';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart' as domain;
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/adapters/remote_media/native_remote_media_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/remote_media/remote_media_host_api.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart' as pigeon;

void main() {
  group('NativeRemoteMediaAdapter', () {
    for (final mapping in <(pigeon.RemoteImageErrorCode, OfflineErrorCode)>[
      (pigeon.RemoteImageErrorCode.cacheMiss, OfflineErrorCode.cacheMiss),
      (pigeon.RemoteImageErrorCode.mediaNotLocal, OfflineErrorCode.mediaNotLocal),
      (pigeon.RemoteImageErrorCode.iCloudUnavailable, OfflineErrorCode.iCloudUnavailable),
      (pigeon.RemoteImageErrorCode.cancelled, OfflineErrorCode.cancelled),
      (pigeon.RemoteImageErrorCode.timeout, OfflineErrorCode.timeout),
      (pigeon.RemoteImageErrorCode.serverUnavailable, OfflineErrorCode.serverUnavailable),
      (pigeon.RemoteImageErrorCode.wrongServer, OfflineErrorCode.wrongServer),
      (pigeon.RemoteImageErrorCode.unauthorized, OfflineErrorCode.unauthorized),
    ]) {
      test('maps ${mapping.$1.name} exhaustively', () async {
        final harness = _Harness();
        final operation = harness.adapter.request(_request());
        harness.host.complete(0, pigeon.RemoteImageResult(error: mapping.$1));

        expect(await operation.result, OfflineResult<OwnedRemoteMediaPayload>.failure(mapping.$2));
        await harness.adapter.dispose();
      });
    }

    test('maps the policy, kind, exact origin, and encoding preference', () async {
      final harness = _Harness();
      final operation = harness.adapter.request(_request(policy: domain.RemoteMediaPolicy.cacheOnly));
      final request = harness.host.requests.single;

      expect(request.url, 'https://photos.example.test/api/assets/1/thumbnail?edited=true');
      expect(request.origin, 'https://photos.example.test');
      expect(request.policy, pigeon.RemoteImagePolicy.cacheOnly);
      expect(request.kind, pigeon.RemoteImageRequestKind.thumbnail);
      expect(request.preferEncoded, isFalse);

      harness.host.complete(0, pigeon.RemoteImageResult(error: pigeon.RemoteImageErrorCode.cacheMiss));
      await operation.result;
      await harness.adapter.dispose();
    });

    test('maps an explicit original request kind to the host API', () async {
      final harness = _Harness();
      final operation = harness.adapter.request(_request(kind: domain.MediaRequestKind.original, preferEncoded: true));

      expect(harness.host.requests.single.kind, pigeon.RemoteImageRequestKind.original);
      expect(harness.host.requests.single.preferEncoded, isTrue);

      harness.host.complete(0, pigeon.RemoteImageResult(error: pigeon.RemoteImageErrorCode.cacheMiss));
      await operation.result;
      await harness.adapter.dispose();
    });

    test('channel and malformed XOR results fail closed and release raw payloads', () async {
      final channelHarness = _Harness();
      final channelOperation = channelHarness.adapter.request(_request());
      channelHarness.host.fail(0, StateError('channel failed'));
      expect(
        await channelOperation.result,
        const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      await channelHarness.adapter.dispose();

      final malformedHarness = _Harness();
      final malformedOperation = malformedHarness.adapter.request(_request());
      malformedHarness.host.complete(
        0,
        pigeon.RemoteImageResult(
          payload: pigeon.RemoteImagePayload(pointer: 91, width: 1, height: 1, rowBytes: 4),
          error: pigeon.RemoteImageErrorCode.timeout,
        ),
      );
      expect(
        await malformedOperation.result,
        const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      expect(malformedHarness.releasedAddresses, [91]);
      await malformedHarness.adapter.dispose();
    });

    test('owned lease releases exactly once', () async {
      final harness = _Harness();
      final operation = harness.adapter.request(_request());
      harness.host.complete(
        0,
        pigeon.RemoteImageResult(payload: pigeon.RemoteImagePayload(pointer: 12, width: 1, height: 1, rowBytes: 4)),
      );

      final payload = (await operation.result).valueOrNull!;
      payload.release();
      payload.release();
      expect(harness.leases.single.releaseCount, 1);
      await harness.adapter.dispose();
    });

    test('individual cancel is idempotent and releases a late payload', () async {
      final harness = _Harness();
      final operation = harness.adapter.request(_request());

      final first = operation.cancel();
      final second = operation.cancel();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      expect(harness.host.cancelledIds, [1]);
      expect(await operation.result, const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.cancelled));

      harness.host.complete(
        0,
        pigeon.RemoteImageResult(payload: pigeon.RemoteImagePayload(pointer: 33, width: 1, height: 1, rowBytes: 4)),
      );
      await pumpEventQueue();
      expect(harness.releasedAddresses, [33]);
      await harness.adapter.dispose();
    });

    test('request id stays tombstoned until cancel ack', () async {
      final ack = Completer<void>();
      final harness = _Harness(cancelRequest: ack.future);
      final operation = harness.adapter.request(_request());
      final cancellation = operation.cancel();
      await pumpEventQueue();

      final rejected = harness.adapter.request(_request());
      expect(
        await rejected.result,
        const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
      ack.complete();
      await cancellation;

      final accepted = harness.adapter.request(_request());
      expect(harness.host.requests, hasLength(2));
      harness.host.complete(1, pigeon.RemoteImageResult(error: pigeon.RemoteImageErrorCode.timeout));
      expect(await accepted.result, const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.timeout));
      harness.host.complete(0, pigeon.RemoteImageResult(error: pigeon.RemoteImageErrorCode.cancelled));
      await pumpEventQueue();
      await harness.adapter.dispose();
    });

    test('cancelAll drains, rejects during drain, and remains reusable', () async {
      final ack = Completer<void>();
      final harness = _Harness(cancelAll: ack.future);
      final operation = harness.adapter.request(_request());
      final cancellation = harness.adapter.cancelAll();
      await pumpEventQueue();

      expect(await operation.result, const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.cancelled));
      final rejected = harness.adapter.request(_request(requestId: 2));
      expect(
        await rejected.result,
        const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );

      ack.complete();
      await cancellation;
      final accepted = harness.adapter.request(_request(requestId: 3));
      expect(harness.host.requests.last.requestId, 3);
      await accepted.cancel();
      await harness.adapter.dispose();
    });

    test('dispose is terminal, idempotent, and calls the host once', () async {
      final harness = _Harness();
      final first = harness.adapter.dispose();
      final second = harness.adapter.dispose();
      expect(identical(first, second), isTrue);
      await Future.wait([first, second]);
      expect(harness.host.disposeCount, 1);

      final rejected = harness.adapter.request(_request());
      expect(
        await rejected.result,
        const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.mediaUnavailable),
      );
    });
  });
}

domain.RemoteMediaRequest _request({
  int requestId = 1,
  domain.RemoteMediaPolicy policy = domain.RemoteMediaPolicy.cacheThenNetwork,
  domain.MediaRequestKind kind = domain.MediaRequestKind.thumbnail,
  bool preferEncoded = false,
}) {
  return domain.RemoteMediaRequest(
    requestId: requestId,
    resource: Uri.parse('https://photos.example.test/api/assets/1/thumbnail?edited=true'),
    policy: policy,
    kind: kind,
    preferEncoded: preferEncoded,
  );
}

final class _Harness {
  _Harness({Future<void>? cancelRequest, Future<void>? cancelAll})
    : host = _FakeHost(cancelRequest: cancelRequest, cancelAll: cancelAll) {
    adapter = NativeRemoteMediaAdapter(
      api: host,
      leaseFactory: (address, length) {
        final lease = _FakeLease(length);
        leases.add(lease);
        return lease;
      },
      releaseNativeBuffer: releasedAddresses.add,
    );
  }

  final _FakeHost host;
  final List<_FakeLease> leases = [];
  final List<int> releasedAddresses = [];
  late final NativeRemoteMediaAdapter adapter;
}

final class _FakeHost implements RemoteMediaHostApi {
  _FakeHost({Future<void>? cancelRequest, Future<void>? cancelAll})
    : _cancelRequest = cancelRequest ?? Future.value(),
      _cancelAll = cancelAll ?? Future.value();

  final Future<void> _cancelRequest;
  final Future<void> _cancelAll;
  final List<pigeon.RemoteImageRequest> requests = [];
  final List<Completer<pigeon.RemoteImageResult>> results = [];
  final List<int> cancelledIds = [];
  int disposeCount = 0;

  @override
  Future<pigeon.RemoteImageResult> requestImage(pigeon.RemoteImageRequest request) {
    requests.add(request);
    final result = Completer<pigeon.RemoteImageResult>();
    results.add(result);
    return result.future;
  }

  void complete(int index, pigeon.RemoteImageResult result) => results[index].complete(result);

  void fail(int index, Object error) => results[index].completeError(error);

  @override
  Future<void> cancelRequest(int requestId) async {
    cancelledIds.add(requestId);
    await _cancelRequest;
  }

  @override
  Future<void> cancelAll() => _cancelAll;

  @override
  Future<void> dispose() async => disposeCount++;
}

final class _FakeLease implements RemoteMediaPayloadLease {
  _FakeLease(int length) : _bytes = Uint8List(length);

  final Uint8List _bytes;
  int releaseCount = 0;

  @override
  Uint8List get bytes => _bytes;

  @override
  bool get isReleased => releaseCount > 0;

  @override
  void release() {
    if (!isReleased) {
      releaseCount++;
    }
  }
}
