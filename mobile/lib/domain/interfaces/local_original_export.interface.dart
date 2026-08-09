import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';

abstract interface class LocalOriginalExportPort {
  CancellableRequest<OriginalExportResult> export(LocalOriginalExportRequest request);
}
