import 'package:immich_mobile/domain/interfaces/auth_request_context.interface.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';

final class NetworkAuthRequestContextAdapter implements AuthRequestContextPort {
  const NetworkAuthRequestContextAdapter();

  @override
  void block() {
    NetworkRepository.blockRequests();
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
