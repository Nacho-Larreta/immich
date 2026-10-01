import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

abstract interface class ManualUploadStagingPort {
  Future<T> withPreparationGate<T>({required String intentId, required Future<T> Function() action});

  Future<void> pruneUnreferenced(ManualUploadIntent latest);

  Future<ManualUploadStagedComponent> stage({
    required String intentId,
    required ManualUploadComponent component,
    required String borrowedPath,
    required String originalFileName,
  });

  Future<String?> resolve({required String intentId, required ManualUploadStagedComponent component});

  Future<void> removeOwnedComponents({
    required String intentId,
    required Iterable<ManualUploadStagedComponent> components,
  });
}
