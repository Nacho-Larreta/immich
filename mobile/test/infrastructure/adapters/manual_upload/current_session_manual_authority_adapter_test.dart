import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/infrastructure/adapters/manual_upload/current_session_manual_authority_adapter.dart';

void main() {
  const destination = ManualUploadDestination(serverUrl: 'https://photos.example/api', userId: 'user-1');

  test('offline selection still identifies its destination without a current network binding', () {
    final authority = CurrentSessionManualAuthorityAdapter(
      readDestination: () => destination,
      readRegisteredEndpoints: () => const {},
      captureBinding: () => null,
    );

    expect(authority.currentDestination(), destination);
    expect(authority.captureAuthorized(), isNull);
  });

  test('authorized alias and stable destination are captured together', () {
    final alias = Uri.parse('https://lan.example/api');
    final authority = CurrentSessionManualAuthorityAdapter(
      readDestination: () => destination,
      readRegisteredEndpoints: () => {Uri.parse(destination.serverUrl), alias},
      captureBinding: () => _binding(alias),
    );

    final captured = authority.captureAuthorized();

    expect(captured?.destination, destination);
    expect(captured?.binding.apiEndpoint, alias);
    expect(captured?.authorizedEndpoints, contains(alias));
  });

  test('changed account or unregistered same-user server fails closed', () {
    var calls = 0;
    final changing = CurrentSessionManualAuthorityAdapter(
      readDestination: () => ++calls == 1
          ? destination
          : const ManualUploadDestination(serverUrl: 'https://other.example/api', userId: 'user-2'),
      readRegisteredEndpoints: () => {Uri.parse(destination.serverUrl)},
      captureBinding: () => _binding(Uri.parse(destination.serverUrl)),
    );
    expect(changing.captureAuthorized(), isNull);

    final otherServer = CurrentSessionManualAuthorityAdapter(
      readDestination: () => destination,
      readRegisteredEndpoints: () => {Uri.parse(destination.serverUrl)},
      captureBinding: () => _binding(Uri.parse('https://other.example/api')),
    );
    expect(otherServer.captureAuthorized(), isNull);
  });
}

BackupRunBinding _binding(Uri endpoint) => BackupRunBinding(
  userId: 'user-1',
  sessionEpoch: 1,
  probeGeneration: 2,
  nativeGeneration: 3,
  apiEndpoint: endpoint,
  canonicalOrigin: Uri.parse(endpoint.origin),
  schemePolicy: EndpointSchemePolicy.httpsOnly,
  transportEpoch: 1,
  transportRevision: 2,
  localLeaseRevision: 3,
);
