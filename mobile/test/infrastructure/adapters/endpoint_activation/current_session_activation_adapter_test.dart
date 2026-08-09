import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_activation/current_session_activation_adapter.dart';

void main() {
  test('snapshots the shared epoch and fresh login credentials on every activation', () {
    final epochs = SessionEpochController();
    var userId = 'first-user';
    var accessToken = 'first-token';
    var headers = <String, String>{'x-proxy-key': 'first'};
    final session = CurrentSessionActivationAdapter(
      epochs,
      readUserId: () => userId,
      readAccessToken: () => accessToken,
      readHeaders: () => headers,
    );

    final first = session.snapshot();
    epochs.invalidateSession();
    userId = 'second-user';
    accessToken = 'second-token';
    headers = {'x-proxy-key': 'second'};
    final second = session.snapshot();

    expect(first.sessionEpoch, 0);
    expect(first.userId, 'first-user');
    expect(first.accessToken, 'first-token');
    expect(first.customHeaders, {'x-proxy-key': 'first'});
    expect(second.sessionEpoch, 1);
    expect(second.userId, 'second-user');
    expect(second.accessToken, 'second-token');
    expect(second.customHeaders, {'x-proxy-key': 'second'});
  });
}
