import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';

void main() {
  test('a configured endpoint starts reauthentication-required until cache hydration succeeds', () {
    expect(
      remoteAuthenticationPhaseForStoredSession(endpoint: 'https://photos.example.test/api'),
      RemoteAuthenticationPhase.reauthenticationRequired,
    );
  });

  test('no configured endpoint starts unconfigured', () {
    expect(remoteAuthenticationPhaseForStoredSession(endpoint: null), RemoteAuthenticationPhase.unconfigured);
  });
}
