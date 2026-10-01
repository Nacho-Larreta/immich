import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';

enum ManualUploadIntentStatus { pending, preparing, ready, uploading, retryWaiting, cancelling, completed, cancelled }

enum ManualUploadComponent { primary, motion }

final class ManualUploadDestination {
  const ManualUploadDestination({required this.serverUrl, required this.userId});

  final String serverUrl;
  final String userId;

  @override
  bool operator ==(Object other) =>
      other is ManualUploadDestination && other.serverUrl == serverUrl && other.userId == userId;

  @override
  int get hashCode => Object.hash(serverUrl, userId);
}

final class ManualUploadSelection {
  const ManualUploadSelection({
    required this.intentId,
    required this.destination,
    required this.deviceId,
    required this.localAssetId,
    required this.createdAt,
  });

  final String intentId;
  final ManualUploadDestination destination;
  final String deviceId;
  final String localAssetId;
  final DateTime createdAt;
}

final class ManualUploadStagedComponent {
  const ManualUploadStagedComponent({required this.component, required this.relativePath, required this.fileName});

  final ManualUploadComponent component;
  final String relativePath;
  final String fileName;
}

final class ManualUploadAttempt {
  const ManualUploadAttempt({
    required this.taskId,
    required this.generation,
    required this.component,
    required this.operationIdentity,
    required this.nativeGeneration,
  });

  final String taskId;
  final int generation;
  final ManualUploadComponent component;
  final String operationIdentity;
  final int nativeGeneration;

  @override
  bool operator ==(Object other) =>
      other is ManualUploadAttempt &&
      other.taskId == taskId &&
      other.generation == generation &&
      other.component == component &&
      other.operationIdentity == operationIdentity &&
      other.nativeGeneration == nativeGeneration;

  @override
  int get hashCode => Object.hash(taskId, generation, component, operationIdentity, nativeGeneration);
}

final class ManualUploadIntent {
  ManualUploadIntent({
    required this.id,
    required this.destination,
    required this.deviceId,
    required this.localAssetId,
    required this.createdAt,
    this.version = 0,
    this.status = ManualUploadIntentStatus.pending,
    Set<ManualUploadComponent> requiredComponents = const {ManualUploadComponent.primary},
    Map<ManualUploadComponent, ManualUploadStagedComponent> stagedComponents = const {},
    Map<ManualUploadComponent, String> remoteIds = const {},
    this.attemptGeneration = 0,
    this.currentAttempt,
    this.retryCount = 0,
    this.retryAt,
    this.lastFailure,
    this.assetSnapshot,
  }) : requiredComponents = Set.unmodifiable(requiredComponents),
       stagedComponents = Map.unmodifiable(stagedComponents),
       remoteIds = Map.unmodifiable(remoteIds);

  factory ManualUploadIntent.fromSelection(ManualUploadSelection selection) => ManualUploadIntent(
    id: selection.intentId,
    destination: selection.destination,
    deviceId: selection.deviceId,
    localAssetId: selection.localAssetId,
    createdAt: selection.createdAt,
  );

  final String id;
  final ManualUploadDestination destination;
  final String deviceId;
  final String localAssetId;
  final DateTime createdAt;
  final int version;
  final ManualUploadIntentStatus status;
  final Set<ManualUploadComponent> requiredComponents;
  final Map<ManualUploadComponent, ManualUploadStagedComponent> stagedComponents;
  final Map<ManualUploadComponent, String> remoteIds;
  final int attemptGeneration;
  final ManualUploadAttempt? currentAttempt;
  final int retryCount;
  final DateTime? retryAt;
  final String? lastFailure;
  final LocalAsset? assetSnapshot;

  bool get isActive => status != ManualUploadIntentStatus.completed && status != ManualUploadIntentStatus.cancelled;
  bool get isPrepared => requiredComponents.every(stagedComponents.containsKey);
  bool get isConfirmed => requiredComponents.every(remoteIds.containsKey);

  ManualUploadIntent copyWith({
    int? version,
    ManualUploadIntentStatus? status,
    Set<ManualUploadComponent>? requiredComponents,
    Map<ManualUploadComponent, ManualUploadStagedComponent>? stagedComponents,
    Map<ManualUploadComponent, String>? remoteIds,
    int? attemptGeneration,
    ManualUploadAttempt? currentAttempt,
    bool clearAttempt = false,
    int? retryCount,
    DateTime? retryAt,
    bool clearRetryAt = false,
    String? lastFailure,
    bool clearLastFailure = false,
    LocalAsset? assetSnapshot,
  }) => ManualUploadIntent(
    id: id,
    destination: destination,
    deviceId: deviceId,
    localAssetId: localAssetId,
    createdAt: createdAt,
    version: version ?? this.version,
    status: status ?? this.status,
    requiredComponents: requiredComponents ?? this.requiredComponents,
    stagedComponents: stagedComponents ?? this.stagedComponents,
    remoteIds: remoteIds ?? this.remoteIds,
    attemptGeneration: attemptGeneration ?? this.attemptGeneration,
    currentAttempt: clearAttempt ? null : currentAttempt ?? this.currentAttempt,
    retryCount: retryCount ?? this.retryCount,
    retryAt: clearRetryAt ? null : retryAt ?? this.retryAt,
    lastFailure: clearLastFailure ? null : lastFailure ?? this.lastFailure,
    assetSnapshot: assetSnapshot ?? this.assetSnapshot,
  );
}
