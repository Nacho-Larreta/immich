import 'package:immich_mobile/domain/models/server_reachability.model.dart';

abstract interface class ReachabilityStatePublisherPort {
  void publish(ReachabilityState state);
}
