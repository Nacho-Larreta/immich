import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_transport.model.dart';

abstract interface class ManualUploadTransportPort {
  Future<bool> enqueue(ManualUploadEnqueueRequest request);

  Future<ManualUploadObservation> observe(ManualUploadIntent intent);

  Future<bool> cancelAndDrain(ManualUploadIntent intent);

  Future<void> replayUndeliveredUpdates();

  Stream<ManualUploadNativeEvent> get events;

  void forgetAttempt(ManualUploadAttempt attempt);

  void dispose();
}
