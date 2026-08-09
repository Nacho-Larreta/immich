import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/share_sheet.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';

void main() {
  test('original export ports return their cancellable operation unchanged', () {
    final operation = _ExactlyOnceCancellableRequest<OriginalExportResult>(
      const OriginalExportResult.failure(OriginalExportError.cancelled),
    );
    final localPort = _LocalOriginalExportPort(operation);
    final remotePort = _RemoteOriginalExportPort(operation);

    expect(
      localPort.export(
        LocalOriginalExportRequest(
          assetId: 'asset-1',
          suggestedFilename: 'one.jpg',
          policy: LocalOriginalExportPolicy.localOnly,
        ),
      ),
      same(operation),
    );
    expect(
      remotePort.export(
        RemoteOriginalExportRequest(
          resource: Uri.parse('https://photos.example/api/assets/asset-1/original'),
          suggestedFilename: 'one.jpg',
        ),
      ),
      same(operation),
    );
  });

  test('share sheet port stays UI-neutral and follows exact-once cancellation convention', () async {
    const cancelled = ShareResult.failure(ShareSheetFailure(error: ShareSheetError.presentationFailed));
    final operation = _ExactlyOnceCancellableRequest<ShareResult>(cancelled);
    final port = _ShareSheetPort(operation);

    final request = port.share(ShareSheetRequest(paths: const ['/tmp/one.jpg']));
    await Future.wait([request.cancel(), request.cancel()]);

    expect(request, same(operation));
    expect(operation.cancelCount, 1);
    expect(await request.result, cancelled);
  });
}

final class _ExactlyOnceCancellableRequest<T> implements CancellableRequest<T> {
  _ExactlyOnceCancellableRequest(this._result);

  final T _result;
  Future<void>? _cancellation;
  int cancelCount = 0;

  @override
  Future<T> get result => Future.value(_result);

  @override
  Future<void> cancel() => _cancellation ??= _cancelOnce();

  Future<void> _cancelOnce() async {
    cancelCount++;
  }
}

final class _LocalOriginalExportPort implements LocalOriginalExportPort {
  const _LocalOriginalExportPort(this.operation);

  final CancellableRequest<OriginalExportResult> operation;

  @override
  CancellableRequest<OriginalExportResult> export(LocalOriginalExportRequest request) => operation;
}

final class _RemoteOriginalExportPort implements RemoteOriginalExportPort {
  const _RemoteOriginalExportPort(this.operation);

  final CancellableRequest<OriginalExportResult> operation;

  @override
  CancellableRequest<OriginalExportResult> export(RemoteOriginalExportRequest request) => operation;
}

final class _ShareSheetPort implements ShareSheetPort {
  const _ShareSheetPort(this.operation);

  final CancellableRequest<ShareResult> operation;

  @override
  CancellableRequest<ShareResult> share(ShareSheetRequest request) => operation;
}
