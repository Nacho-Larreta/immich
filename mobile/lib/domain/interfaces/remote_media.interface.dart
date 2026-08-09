import 'dart:typed_data';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';

abstract interface class RemoteMediaPort<T> {
  CancellableMediaRequest<T> request(RemoteMediaRequest request);

  Future<void> cancelAll();
}

abstract interface class RemoteMediaPayloadLease {
  Uint8List get bytes;

  bool get isReleased;

  void release();
}

sealed class OwnedRemoteMediaPayload {
  const OwnedRemoteMediaPayload({required this.lease});

  final RemoteMediaPayloadLease lease;

  Uint8List get bytes => lease.bytes;

  bool get isReleased => lease.isReleased;

  void release() => lease.release();
}

final class OwnedRgbaRemoteMediaPayload extends OwnedRemoteMediaPayload {
  const OwnedRgbaRemoteMediaPayload({
    required super.lease,
    required this.widthPx,
    required this.heightPx,
    required this.rowBytes,
  });

  final int widthPx;
  final int heightPx;
  final int rowBytes;
}

final class OwnedEncodedRemoteMediaPayload extends OwnedRemoteMediaPayload {
  const OwnedEncodedRemoteMediaPayload({required super.lease});
}
