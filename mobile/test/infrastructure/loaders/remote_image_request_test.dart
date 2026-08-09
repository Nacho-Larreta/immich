import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('passes the explicit policy and resource to the remote media port', () async {
    final operation = _Operation(
      result: const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.cacheMiss),
    );
    final port = _Port(operation);
    final request = _request(port, policy: RemoteMediaPolicy.cacheOnly);

    await expectLater(
      request.load(_unusedDecoder),
      throwsA(isA<RemoteMediaLoadFailure>().having((failure) => failure.code, 'code', OfflineErrorCode.cacheMiss)),
    );
    expect(port.requests.single.policy, RemoteMediaPolicy.cacheOnly);
    expect(port.requests.single.resource, Uri.parse('https://photos.example.test/api/assets/1/thumbnail'));
    expect(port.requests.single.kind, MediaRequestKind.thumbnail);
    expect(port.requests.single.preferEncoded, isFalse);
  });

  test('passes explicit original kind for codec requests', () async {
    final operation = _Operation(
      result: const OfflineResult<OwnedRemoteMediaPayload>.failure(OfflineErrorCode.cacheMiss),
    );
    final port = _Port(operation);
    final request = _request(port, kind: MediaRequestKind.original);

    await expectLater(request.loadCodec(), throwsA(isA<RemoteMediaLoadFailure>()));

    expect(port.requests.single.kind, MediaRequestKind.original);
    expect(port.requests.single.preferEncoded, isTrue);
  });

  test('cancelled is silent and cancellation consumes native channel failures', () async {
    final operation = _Operation(cancelError: StateError('cancel channel failed'));
    final request = _request(_Port(operation));
    final load = request.load(_unusedDecoder);
    await pumpEventQueue();
    final zoneErrors = <Object>[];

    await runZonedGuarded<Future<void>>(() async {
      request.cancel();
      await pumpEventQueue();
    }, (error, _) => zoneErrors.add(error));

    expect(zoneErrors, isEmpty);
    expect(operation.cancelCount, 1);
    expect(await load, isNull);
  });

  test('decode failure releases the owned payload exactly once', () async {
    final lease = _Lease(Uint8List(1));
    final operation = _Operation(
      result: OfflineResult.success(OwnedRgbaRemoteMediaPayload(lease: lease, widthPx: 1, heightPx: 1, rowBytes: 4)),
    );
    final request = _request(_Port(operation));

    await expectLater(request.load(_unusedDecoder), throwsA(anything));
    expect(lease.releaseCount, 1);
    lease.release();
    expect(lease.releaseCount, 1);
  });
}

RemoteImageRequest _request(
  RemoteMediaPort<OwnedRemoteMediaPayload> port, {
  RemoteMediaPolicy policy = RemoteMediaPolicy.cacheThenNetwork,
  MediaRequestKind kind = MediaRequestKind.thumbnail,
}) {
  return RemoteImageRequest(
    media: port,
    uri: 'https://photos.example.test/api/assets/1/thumbnail',
    policy: policy,
    kind: kind,
  );
}

Future<ui.Codec> _unusedDecoder(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
  throw StateError('the remote loader owns decoding');
}

final class _Port implements RemoteMediaPort<OwnedRemoteMediaPayload> {
  _Port(this.operation);

  final _Operation operation;
  final List<RemoteMediaRequest> requests = [];

  @override
  CancellableMediaRequest<OwnedRemoteMediaPayload> request(RemoteMediaRequest request) {
    requests.add(request);
    return operation;
  }

  @override
  Future<void> cancelAll() async {}
}

final class _Operation implements CancellableMediaRequest<OwnedRemoteMediaPayload> {
  _Operation({OfflineResult<OwnedRemoteMediaPayload>? result, this.cancelError}) {
    if (result != null) {
      _result.complete(result);
    }
  }

  final Completer<OfflineResult<OwnedRemoteMediaPayload>> _result = Completer();
  final Object? cancelError;
  int cancelCount = 0;

  @override
  Stream<MediaRequestProgress> get progress => const Stream.empty();

  @override
  Future<OfflineResult<OwnedRemoteMediaPayload>> get result => _result.future;

  @override
  Future<void> cancel() async {
    cancelCount++;
    if (!_result.isCompleted) {
      _result.complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    }
    final error = cancelError;
    if (error != null) {
      throw error;
    }
  }
}

final class _Lease implements RemoteMediaPayloadLease {
  _Lease(this._bytes);

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
