package app.alextran.immich.share

class OriginalExportApiImpl : OriginalExportApi {
  override fun exportLocal(
    request: LocalOriginalExportRequest,
    callback: (Result<OriginalExportResult>) -> Unit,
  ) {
    callback(Result.success(OriginalExportResult(error = OriginalExportErrorCode.PLATFORM_UNSUPPORTED)))
  }

  override fun exportRemote(
    request: RemoteOriginalExportRequest,
    callback: (Result<OriginalExportResult>) -> Unit,
  ) {
    callback(Result.success(OriginalExportResult(error = OriginalExportErrorCode.PLATFORM_UNSUPPORTED)))
  }

  override fun cancelRequest(requestId: Long, callback: (Result<Unit>) -> Unit) {
    callback(Result.success(Unit))
  }

  override fun cancelAll(callback: (Result<Unit>) -> Unit) {
    callback(Result.success(Unit))
  }

  override fun dispose(callback: (Result<Unit>) -> Unit) {
    callback(Result.success(Unit))
  }

  override fun releaseLease(
    leaseToken: String,
    callback: (Result<OriginalExportReleaseResult>) -> Unit,
  ) {
    callback(Result.success(OriginalExportReleaseResult(error = OriginalExportErrorCode.LEASE_NOT_FOUND)))
  }
}
