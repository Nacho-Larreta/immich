import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

abstract interface class ManualUploadSubmissionPort {
  Future<List<ManualUploadIntent>> submit(List<ManualUploadSelection> selections);

  Future<void> requestCancel(String intentId);
}
