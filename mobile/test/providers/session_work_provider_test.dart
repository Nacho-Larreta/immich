import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/session_work.provider.dart';

void main() {
  test('activates reachability and starts local sync without waiting for it', () async {
    final localSync = Completer<void>();
    final events = <String>[];
    final work = SessionWork(
      activateSession: ({confirmedEndpoint}) => events.add('activate:$confirmedEndpoint'),
      syncLocal: ({required full}) {
        events.add('syncLocal:$full');
        return localSync.future;
      },
      cancelLocalSync: () async {},
    );

    work.activate(confirmedEndpoint: Uri.parse('https://photos.example.test/api'), fullLocalSync: true);

    expect(events, ['activate:https://photos.example.test/api', 'syncLocal:true']);
    expect(localSync.isCompleted, isFalse);
    localSync.complete();
    await pumpEventQueue();
  });

  test('can re-dispatch local-only sync after lifecycle cancellation', () async {
    final fullModes = <bool>[];
    final work = SessionWork(
      activateSession: ({confirmedEndpoint}) {},
      syncLocal: ({required full}) async => fullModes.add(full),
      cancelLocalSync: () async {},
    );

    work.triggerLocalSync(full: false);
    work.triggerLocalSync(full: true);
    await pumpEventQueue();

    expect(fullModes, [false, true]);
  });
}
