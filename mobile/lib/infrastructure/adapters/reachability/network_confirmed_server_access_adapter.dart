import 'package:immich_mobile/domain/interfaces/confirmed_server_access.interface.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

final class NetworkConfirmedServerAccessAdapter implements ConfirmedServerAccessPort {
  const NetworkConfirmedServerAccessAdapter();

  @override
  ConfirmedServerAccess? read() {
    final evidence = NetworkRepository.serverAccessEvidence;
    final endpoint = evidence.apiEndpoint;
    if (endpoint == null || evidence.canonicalOrigin == null || evidence.schemePolicy == null) {
      return null;
    }
    try {
      return ConfirmedServerAccess(
        apiEndpoint: endpoint,
        canonicalOrigin: evidence.canonicalOrigin!,
        schemePolicy: evidence.schemePolicy!,
        nativeContextGeneration: evidence.generation,
        confirmed: evidence.confirmed,
        fenced: evidence.fenced,
      );
    } on ArgumentError {
      return null;
    }
  }
}
