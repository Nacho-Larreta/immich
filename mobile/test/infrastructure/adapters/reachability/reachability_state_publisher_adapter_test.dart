import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/reachability/reachability_state_publisher_adapter.dart';

void main() {
  test('publishes the exact coordinator state', () {
    ReachabilityState? published;
    final publisher = ReachabilityStatePublisherAdapter((state) => published = state);
    final state = ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 3,
      probeGeneration: 7,
      confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
    );

    publisher.publish(state);

    expect(identical(published, state), isTrue);
  });
}
