import 'package:immich_mobile/platform/original_export_api.g.dart' as pigeon;

abstract interface class OriginalExportHostApi {
  Future<pigeon.OriginalExportResult> exportLocal(pigeon.LocalOriginalExportRequest request);

  Future<pigeon.OriginalExportResult> exportRemote(pigeon.RemoteOriginalExportRequest request);

  Future<void> cancelRequest(int requestId);

  Future<void> cancelAll();

  Future<void> dispose();

  Future<pigeon.OriginalExportReleaseResult> releaseLease(String leaseToken);
}

final class PigeonOriginalExportHostApi implements OriginalExportHostApi {
  const PigeonOriginalExportHostApi({required pigeon.OriginalExportApi api}) : _api = api;

  final pigeon.OriginalExportApi _api;

  @override
  Future<pigeon.OriginalExportResult> exportLocal(pigeon.LocalOriginalExportRequest request) {
    return _api.exportLocal(request);
  }

  @override
  Future<pigeon.OriginalExportResult> exportRemote(pigeon.RemoteOriginalExportRequest request) {
    return _api.exportRemote(request);
  }

  @override
  Future<void> cancelRequest(int requestId) => _api.cancelRequest(requestId);

  @override
  Future<void> cancelAll() => _api.cancelAll();

  @override
  Future<void> dispose() => _api.dispose();

  @override
  Future<pigeon.OriginalExportReleaseResult> releaseLease(String leaseToken) => _api.releaseLease(leaseToken);
}
