import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/endpoint_activation_collaborators.dart';
import 'package:immich_mobile/services/api.service.dart';

final class CurrentSessionActivationAdapter implements ActivationSessionPort {
  CurrentSessionActivationAdapter(
    this._epochs, {
    String Function()? readUserId,
    String Function()? readAccessToken,
    Map<String, String> Function()? readHeaders,
  }) : _readUserId = readUserId ?? _currentUserId,
       _readAccessToken = readAccessToken ?? _currentAccessToken,
       _readHeaders = readHeaders ?? ApiService.getRequestHeaders;

  final SessionEpochController _epochs;
  final String Function() _readUserId;
  final String Function() _readAccessToken;
  final Map<String, String> Function() _readHeaders;

  @override
  ActivationSessionSnapshot snapshot() {
    final identity = _epochs.current;
    return ActivationSessionSnapshot(
      sessionEpoch: identity.sessionEpoch,
      probeGeneration: identity.probeGeneration,
      userId: _readUserId(),
      accessToken: _readAccessToken(),
      customHeaders: _readHeaders(),
    );
  }
}

String _currentUserId() => Store.get(StoreKey.currentUser).id;

String _currentAccessToken() => Store.get(StoreKey.accessToken);
