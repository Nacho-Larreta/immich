import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/pages/common/splash_session.dart';

void main() {
  group('SplashSessionBootstrap', () {
    test('navigates from cache without waiting for pending remote work', () async {
      final remoteWork = Completer<void>();
      final navigations = <SplashDestination>[];
      var hydrationCalls = 0;
      var remoteTriggers = 0;
      final bootstrap = SplashSessionBootstrap(
        hydrateCachedSession: () {
          hydrationCalls++;
          return true;
        },
        navigate: (destination) async => navigations.add(destination),
        triggerPostNavigationWork: ({required hasRemoteAuthentication}) {
          expect(hasRemoteAuthentication, isTrue);
          remoteTriggers++;
          return remoteWork.future;
        },
      );

      await bootstrap.run();

      expect(navigations, [SplashDestination.timeline]);
      expect(hydrationCalls, 1);
      expect(remoteTriggers, 1);
      expect(remoteWork.isCompleted, isFalse);
    });

    test('opens the local timeline and starts local work when no remote session is cached', () async {
      final navigations = <SplashDestination>[];
      var postNavigationTriggers = 0;
      final bootstrap = SplashSessionBootstrap(
        hydrateCachedSession: () => false,
        navigate: (destination) async => navigations.add(destination),
        triggerPostNavigationWork: ({required hasRemoteAuthentication}) async {
          expect(hasRemoteAuthentication, isFalse);
          postNavigationTriggers++;
        },
      );

      await bootstrap.run();

      expect(navigations, [SplashDestination.timeline]);
      expect(postNavigationTriggers, 1);
    });
  });
}
