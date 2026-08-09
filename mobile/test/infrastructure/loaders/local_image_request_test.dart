import 'dart:async';
import 'dart:typed_data';
import 'dart:ui' as ui;

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/infrastructure/loaders/image_request.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('cancelling the loader cancels its injected media operation', () async {
    final operation = _Operation();
    final request = _request(_Port(operation));
    final load = request.load(_unusedDecoder);
    await pumpEventQueue();

    request.cancel();
    await pumpEventQueue();

    expect(operation.cancelCount, 1);
    expect(await load, isNull);
  });

  test('decode failure still releases owned payload exactly once', () async {
    final lease = _Lease(Uint8List(1));
    final operation = _Operation(
      result: OfflineResult.success(OwnedRgbaLocalMediaPayload(lease: lease, widthPx: 1, heightPx: 1, rowBytes: 4)),
    );
    final request = _request(_Port(operation));

    await expectLater(request.load(_unusedDecoder), throwsA(anything));
    expect(lease.releaseCount, 1);
    lease.release();
    expect(lease.releaseCount, 1);
  });

  test('encoded decode failure releases its owned payload exactly once', () async {
    final lease = _Lease(Uint8List(1));
    final operation = _Operation(result: OfflineResult.success(OwnedEncodedLocalMediaPayload(lease: lease)));
    final request = _request(_Port(operation), rendition: const LocalMediaRendition.originalEncoded());

    await expectLater(request.load(_unusedDecoder), throwsA(anything));
    expect(lease.releaseCount, 1);
    lease.release();
    expect(lease.releaseCount, 1);
  });

  test('void loader cancellation consumes async handle failures without a zone error', () async {
    final operation = _Operation(cancelError: StateError('native cancel failed'));
    final request = _request(_Port(operation));
    final load = request.load(_unusedDecoder);
    await pumpEventQueue();
    final zoneErrors = <Object>[];

    final cancellation = runZonedGuarded<Future<void>>(() async {
      request.cancel();
      await pumpEventQueue();
    }, (error, _) => zoneErrors.add(error));
    await cancellation;

    expect(zoneErrors, isEmpty);
    expect(operation.cancelCount, 1);
    expect(await load, isNull);
  });
}

LocalImageRequest _request(LocalMediaPort<OwnedLocalMediaPayload> port, {LocalMediaRendition? rendition}) {
  return LocalImageRequest(
    media: port,
    assetId: 'asset-1',
    assetType: AssetType.image,
    policy: LocalMediaPolicy.localOnly,
    rendition: rendition ?? LocalMediaRendition.thumbnail(widthPx: 1, heightPx: 1),
  );
}

Future<ui.Codec> _unusedDecoder(ui.ImmutableBuffer buffer, {ui.TargetImageSizeCallback? getTargetSize}) {
  throw StateError('the local loader owns decoding');
}

final class _Port implements LocalMediaPort<OwnedLocalMediaPayload> {
  _Port(this.operation);

  final _Operation operation;

  @override
  CancellableMediaRequest<OwnedLocalMediaPayload> request(LocalMediaRequest request) => operation;

  @override
  Future<void> cancelAll() async {}
}

final class _Operation implements CancellableMediaRequest<OwnedLocalMediaPayload> {
  _Operation({OfflineResult<OwnedLocalMediaPayload>? result, this.cancelError}) {
    if (result != null) {
      _result.complete(result);
    }
  }

  final Completer<OfflineResult<OwnedLocalMediaPayload>> _result = Completer();
  final Object? cancelError;
  int cancelCount = 0;

  @override
  Stream<MediaRequestProgress> get progress => const Stream.empty();

  @override
  Future<OfflineResult<OwnedLocalMediaPayload>> get result => _result.future;

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

final class _Lease implements LocalMediaPayloadLease {
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
