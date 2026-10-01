import 'package:immich_mobile/domain/interfaces/manual_upload_authority.interface.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/network_uri.model.dart';

final class CurrentSessionManualAuthorityAdapter implements ManualUploadAuthoritySourcePort {
  const CurrentSessionManualAuthorityAdapter({
    required ManualUploadDestination? Function() readDestination,
    required Set<Uri> Function() readRegisteredEndpoints,
    required BackupRunBinding? Function() captureBinding,
  }) : _readDestination = readDestination,
       _readRegisteredEndpoints = readRegisteredEndpoints,
       _captureBinding = captureBinding;

  final ManualUploadDestination? Function() _readDestination;
  final Set<Uri> Function() _readRegisteredEndpoints;
  final BackupRunBinding? Function() _captureBinding;

  @override
  ManualUploadDestination? currentDestination() {
    final destination = _readDestination();
    if (destination == null || destination.userId.isEmpty) return null;
    final uri = Uri.tryParse(destination.serverUrl);
    if (uri == null) return null;
    try {
      validateHttpEndpoint(uri, 'serverUrl');
    } on ArgumentError {
      return null;
    }
    return destination;
  }

  @override
  ManualUploadAuthority? captureAuthorized() {
    final before = currentDestination();
    if (before == null) return null;
    final beforeEndpoints = _readRegisteredEndpoints();
    final binding = _captureBinding();
    final after = currentDestination();
    final afterEndpoints = _readRegisteredEndpoints();
    if (binding == null || before != after || binding.userId != before.userId) return null;
    if (beforeEndpoints.length != afterEndpoints.length || !beforeEndpoints.containsAll(afterEndpoints)) return null;
    if (!beforeEndpoints.contains(binding.apiEndpoint)) return null;
    return ManualUploadAuthority(
      destination: before,
      binding: binding,
      authorizedEndpoints: Set.unmodifiable(beforeEndpoints),
    );
  }
}
