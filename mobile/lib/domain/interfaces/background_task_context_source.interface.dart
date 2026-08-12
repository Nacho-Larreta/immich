import 'package:immich_mobile/domain/models/background_task.model.dart';

abstract interface class BackgroundTaskContextSourcePort {
  BackgroundTaskContextBinding? capture();
}
