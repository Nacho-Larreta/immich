import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

enum ManualUploadObservationState { active, succeeded, failed, cancelled, absent, unknown }

final class ManualUploadObservation {
  const ManualUploadObservation(this.state, {this.remoteAssetId, this.failureCode});

  final ManualUploadObservationState state;
  final String? remoteAssetId;
  final String? failureCode;
}

final class ManualUploadNativeEvent {
  const ManualUploadNativeEvent({
    required this.intentId,
    required this.taskId,
    required this.generation,
    required this.component,
    required this.destination,
    required this.observation,
    this.progress,
  });

  final String intentId;
  final String taskId;
  final int generation;
  final ManualUploadComponent component;
  final ManualUploadDestination destination;
  final ManualUploadObservation observation;
  final double? progress;
}

final class ManualUploadEnqueueRequest {
  const ManualUploadEnqueueRequest({
    required this.intent,
    required this.staged,
    required this.asset,
    required this.binding,
    required this.currentDestination,
    required this.authorizedEndpoints,
    required this.absolutePath,
  });

  final ManualUploadIntent intent;
  final ManualUploadStagedComponent staged;
  final LocalAsset asset;
  final BackupRunBinding binding;
  final ManualUploadDestination currentDestination;
  final Set<Uri> authorizedEndpoints;
  final String absolutePath;
}
