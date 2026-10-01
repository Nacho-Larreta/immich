import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

void validateManualUploadIntent(ManualUploadIntent intent) {
  if (intent.assetSnapshot != null && intent.assetSnapshot?.id != intent.localAssetId) {
    throw ArgumentError('Manual upload source metadata must belong to the selected asset');
  }
  final server = Uri.tryParse(intent.destination.serverUrl);
  if (intent.id.isEmpty ||
      intent.id.contains('/') ||
      intent.id.contains('\\') ||
      intent.id == '.' ||
      intent.id == '..' ||
      intent.deviceId.isEmpty ||
      intent.localAssetId.isEmpty ||
      intent.destination.userId.isEmpty ||
      server == null ||
      !{'http', 'https'}.contains(server.scheme) ||
      server.host.isEmpty ||
      server.userInfo.isNotEmpty ||
      server.hasQuery ||
      server.hasFragment ||
      intent.version < 0 ||
      intent.attemptGeneration < 0 ||
      intent.retryCount < 0) {
    throw ArgumentError('Invalid manual upload identity or revision');
  }
  if (!intent.requiredComponents.contains(ManualUploadComponent.primary) ||
      intent.remoteIds.entries.any((entry) => !intent.requiredComponents.contains(entry.key) || entry.value.isEmpty)) {
    throw ArgumentError('Invalid manual upload media components');
  }
  for (final entry in intent.stagedComponents.entries) {
    final staged = entry.value;
    final segments = staged.relativePath.split('/');
    if (!intent.requiredComponents.contains(entry.key) ||
        entry.key != staged.component ||
        segments.length < 2 ||
        segments.first != intent.id ||
        segments.any((segment) => segment.isEmpty || segment == '.' || segment == '..') ||
        staged.relativePath.contains('\\') ||
        staged.fileName.isEmpty) {
      throw ArgumentError('Manual upload staging must remain inside its intent directory');
    }
  }
  _validateAttempt(intent);
  if ((intent.status == ManualUploadIntentStatus.ready || intent.status == ManualUploadIntentStatus.uploading) &&
      !intent.isPrepared) {
    throw ArgumentError('Manual upload cannot run before all components are staged');
  }
  if (intent.status == ManualUploadIntentStatus.completed && (!intent.isConfirmed || intent.currentAttempt != null)) {
    throw ArgumentError('Manual upload requires settled server confirmations');
  }
  if (intent.status == ManualUploadIntentStatus.cancelled && intent.currentAttempt != null) {
    throw ArgumentError('Manual upload cancellation requires native drain');
  }
}

void _validateAttempt(ManualUploadIntent intent) {
  final attempt = intent.currentAttempt;
  if (attempt == null) {
    if (intent.status == ManualUploadIntentStatus.uploading) throw ArgumentError('Missing manual upload attempt');
    return;
  }
  if (attempt.taskId.isEmpty ||
      attempt.generation <= 0 ||
      attempt.generation != intent.attemptGeneration ||
      attempt.operationIdentity.isEmpty ||
      attempt.nativeGeneration < 0 ||
      !intent.stagedComponents.containsKey(attempt.component) ||
      intent.remoteIds.containsKey(attempt.component) ||
      !{ManualUploadIntentStatus.uploading, ManualUploadIntentStatus.cancelling}.contains(intent.status)) {
    throw ArgumentError('Invalid manual upload attempt');
  }
  if (attempt.component == ManualUploadComponent.primary &&
      intent.requiredComponents.contains(ManualUploadComponent.motion) &&
      !intent.remoteIds.containsKey(ManualUploadComponent.motion)) {
    throw ArgumentError('Live Photo motion must be confirmed before its still image');
  }
}

void validateManualUploadTransition(ManualUploadIntent previous, ManualUploadIntent next) {
  validateManualUploadIntent(next);
  if (previous.assetSnapshot != null && previous.assetSnapshot != next.assetSnapshot) {
    throw ArgumentError('Manual upload source metadata is immutable after preparation starts');
  }
  if (previous.id != next.id ||
      previous.destination != next.destination ||
      previous.deviceId != next.deviceId ||
      previous.localAssetId != next.localAssetId ||
      previous.createdAt != next.createdAt ||
      next.version != previous.version + 1) {
    throw ArgumentError('Manual upload transition must preserve identity and advance exactly one version');
  }
  if (!previous.isActive ||
      (previous.status == ManualUploadIntentStatus.cancelling &&
          !{ManualUploadIntentStatus.cancelling, ManualUploadIntentStatus.cancelled}.contains(next.status))) {
    throw ArgumentError('A settled or cancelling manual intent cannot be restarted');
  }
  if (previous.remoteIds.entries.any((entry) => next.remoteIds[entry.key] != entry.value) ||
      !next.requiredComponents.containsAll(previous.requiredComponents)) {
    throw ArgumentError('Manual upload cannot forget confirmed media components');
  }
  final changedAttempt = next.currentAttempt != null && next.currentAttempt != previous.currentAttempt;
  if (changedAttempt && next.status == ManualUploadIntentStatus.cancelling) {
    throw ArgumentError('A cancelling manual intent cannot admit new work');
  }
  if (next.attemptGeneration != previous.attemptGeneration + (changedAttempt ? 1 : 0) ||
      (changedAttempt && previous.currentAttempt != null)) {
    throw ArgumentError('Manual upload attempt must reserve a fresh generation after prior drain');
  }
  if (next.requiredComponents.length != previous.requiredComponents.length &&
      (previous.attemptGeneration != 0 || previous.remoteIds.isNotEmpty)) {
    throw ArgumentError('Manual upload component discovery must precede native attempts');
  }
}
