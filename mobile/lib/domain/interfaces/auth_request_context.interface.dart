import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';

abstract interface class AuthRequestContextPort {
  void block();

  Future<void> install({
    required Uri canonicalOrigin,
    required String accessToken,
    required EndpointSchemePolicy schemePolicy,
    required Map<String, String> customHeaders,
  });

  Future<void> purge();

  void publishCleared();
}

abstract interface class AuthApiGraphPort {
  Future<void> purge();
}
