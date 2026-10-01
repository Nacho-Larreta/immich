import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';

final class ManualUploadAuthority {
  const ManualUploadAuthority({required this.destination, required this.binding, required this.authorizedEndpoints});

  final ManualUploadDestination destination;
  final BackupRunBinding binding;
  final Set<Uri> authorizedEndpoints;

  bool sameSessionAs(ManualUploadAuthority other) =>
      destination == other.destination &&
      binding == other.binding &&
      authorizedEndpoints.length == other.authorizedEndpoints.length &&
      authorizedEndpoints.containsAll(other.authorizedEndpoints);
}

abstract interface class ManualUploadAuthoritySourcePort {
  ManualUploadDestination? currentDestination();

  ManualUploadAuthority? captureAuthorized();
}
