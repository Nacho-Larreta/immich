import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

final class NetworkAuthRequestContextAdapter implements AuthRequestContextPort {
  const NetworkAuthRequestContextAdapter(this._currentSessionEpoch);

  final int Function() _currentSessionEpoch;

  @override
  void block() {
    NetworkRepository.blockRequests();
  }

  @override
  Future<void> install({
    required Uri apiEndpoint,
    required Uri canonicalOrigin,
    required String accessToken,
    required EndpointSchemePolicy schemePolicy,
    required Map<String, String> customHeaders,
  }) {
    if (schemePolicy == EndpointSchemePolicy.registeredLocalHttp &&
        !NetworkRepository.hasConfirmedRequestContext(canonicalOrigin)) {
      return Future.error(StateError('Registered local HTTP requires a confirmed WiFi-bound activation'));
    }
    return NetworkRepository.replaceRequestContext(
      headers: customHeaders,
      apiEndpoint: apiEndpoint,
      canonicalOrigin: canonicalOrigin,
      token: accessToken,
      schemePolicy: schemePolicy,
      sessionEpoch: _currentSessionEpoch(),
    );
  }

  @override
  Future<void> purge() {
    return NetworkRepository.purgeRequestContext();
  }

  @override
  void publishCleared() {
    NetworkRepository.publishClearedContext();
  }
}
