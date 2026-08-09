import 'dart:typed_data';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';

abstract interface class LocalMediaPort<T> {
  CancellableMediaRequest<T> request(LocalMediaRequest request);

  Future<void> cancelAll();
}

abstract interface class LocalMediaPayloadLease {
  Uint8List get bytes;

  bool get isReleased;

  void release();
}

sealed class OwnedLocalMediaPayload {
  const OwnedLocalMediaPayload({required this.lease});

  final LocalMediaPayloadLease lease;

  Uint8List get bytes => lease.bytes;

  bool get isReleased => lease.isReleased;

  void release() => lease.release();
}

final class OwnedRgbaLocalMediaPayload extends OwnedLocalMediaPayload {
  const OwnedRgbaLocalMediaPayload({
    required super.lease,
    required this.widthPx,
    required this.heightPx,
    required this.rowBytes,
  });

  final int widthPx;
  final int heightPx;
  final int rowBytes;
}

final class OwnedEncodedLocalMediaPayload extends OwnedLocalMediaPayload {
  const OwnedEncodedLocalMediaPayload({required super.lease});
}
