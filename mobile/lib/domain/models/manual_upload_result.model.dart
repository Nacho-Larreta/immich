enum ManualAssetUploadState { succeeded, failed, pending, cancelled }

final class ManualAssetUploadOutcome {
  const ManualAssetUploadOutcome({
    required this.localAssetId,
    required this.state,
    this.remoteAssetId,
    this.motionRemoteId,
    this.errorMessage,
  }) : assert(state != ManualAssetUploadState.succeeded || remoteAssetId != null);

  final String localAssetId;
  final ManualAssetUploadState state;
  final String? remoteAssetId;
  final String? motionRemoteId;
  final String? errorMessage;
}

final class ManualUploadResult {
  const ManualUploadResult(this.outcomes);

  final List<ManualAssetUploadOutcome> outcomes;

  int get requestedCount => outcomes.length;
  int get succeededCount => _count(ManualAssetUploadState.succeeded);
  int get failedCount => _count(ManualAssetUploadState.failed);
  int get pendingCount => _count(ManualAssetUploadState.pending);
  int get cancelledCount => _count(ManualAssetUploadState.cancelled);
  bool get allSucceeded => succeededCount == requestedCount;

  int _count(ManualAssetUploadState state) => outcomes.where((outcome) => outcome.state == state).length;
}
