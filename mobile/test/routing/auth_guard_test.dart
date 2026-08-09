import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/routing/auth_guard.dart';

void main() {
  test('auth guard invalidation path always coordinates navigation and logout', () async {
    final events = <String>[];
    final invalidator = AuthGuardSessionInvalidator(() async => events.add('coordinator.logout'));

    await invalidator.redirect(() async => events.add('navigate.login'));

    expect(events, containsAll(['navigate.login', 'coordinator.logout']));
  });

  test('still invalidates the coordinated session when navigation fails', () async {
    var invalidationCalls = 0;
    final invalidator = AuthGuardSessionInvalidator(() async => invalidationCalls++);

    await expectLater(
      invalidator.redirect(() async => throw StateError('navigation failed')),
      throwsA(isA<StateError>()),
    );

    expect(invalidationCalls, 1);
  });
}
