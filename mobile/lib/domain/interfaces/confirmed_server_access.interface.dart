import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';

abstract interface class ConfirmedServerAccessPort {
  ConfirmedServerAccess? read();
}
