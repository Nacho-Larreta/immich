import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/background_task.model.dart';

abstract interface class BackgroundTaskRunner {
  CancellableRequest<Object?> start({required BackgroundTaskDescriptor task, String? debugLabel});
}
