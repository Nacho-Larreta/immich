import 'package:immich_mobile/domain/interfaces/reachability_state_publisher.interface.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';

final class ReachabilityStatePublisherAdapter implements ReachabilityStatePublisherPort {
  const ReachabilityStatePublisherAdapter(this._publish);

  final void Function(ReachabilityState state) _publish;

  @override
  void publish(ReachabilityState state) => _publish(state);
}
