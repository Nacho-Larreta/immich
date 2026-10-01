import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

abstract interface class ManualUploadOutbox {
  Future<List<ManualUploadIntent>> submit(List<ManualUploadSelection> selections);

  Future<ManualUploadIntent?> read(String intentId);

  Future<List<ManualUploadIntent>> listActive(ManualUploadDestination destination, {int limit = 100, String? afterId});

  Future<bool> compareAndSet(ManualUploadIntent expected, ManualUploadIntent next);

  Stream<void> get changes;
}
