import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';

final class TemporaryFileWriteRequest {
  TemporaryFileWriteRequest({required this.suggestedName, required this.content}) {
    if (suggestedName.isEmpty || suggestedName.contains('/') || suggestedName.contains(r'\')) {
      throw ArgumentError.value(suggestedName, 'suggestedName', 'Must be a plain non-empty filename');
    }
  }

  final String suggestedName;
  final Stream<List<int>> content;
}

abstract interface class TemporaryFilesPort<T> {
  CancellableRequest<OfflineResult<T>> write(TemporaryFileWriteRequest request);

  CancellableRequest<OfflineResult<OperationCompletion>> delete(T temporaryFile);
}
