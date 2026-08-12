import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/providers/app_life_cycle.provider.dart';

void main() {
  test('resume waits for the worker lock before reachability and local sync', () async {
    final lock = Completer<void>();
    final events = <String>[];
    final work = LifecycleSessionWork(
      pauseReachability: () async => events.add('coordinator.pause'),
      resumeReachability: () => events.add('coordinator.resume'),
      triggerLocalSync: ({required full}) => events.add('syncLocal:$full'),
      cancelLocalSync: () async => events.add('syncLocal.cancel'),
      cancelBackgroundSync: () async => events.add('backgroundSync.cancel'),
      stopBackup: () => events.add('backup.stop'),
      pauseEagerBackup: () async => events.add('eager.handoff'),
      resumeEagerBackup: () => events.add('eager.resume'),
      disconnectWebsocket: () => events.add('websocket.disconnect'),
      lockBackgroundWorker: () {
        events.add('worker.lock');
        return lock.future;
      },
      unlockBackgroundWorker: () async => events.add('worker.unlock'),
    );

    final resume = work.resume(fullLocalSync: true);
    await pumpEventQueue();

    expect(events, ['worker.lock']);
    lock.complete();
    await resume;

    expect(events, ['worker.lock', 'coordinator.resume', 'eager.resume', 'syncLocal:true']);
  });

  test('pause drains reconciliation, local sync, and accepted websocket work before unlocking the worker', () async {
    final reconciliation = Completer<void>();
    final localSync = Completer<void>();
    final websocketSync = Completer<void>();
    final foregroundStopped = Completer<void>();
    final events = <String>[];
    final work = LifecycleSessionWork(
      pauseReachability: () {
        events.add('coordinator.pause');
        return reconciliation.future;
      },
      resumeReachability: () => events.add('coordinator.resume'),
      triggerLocalSync: ({required full}) => events.add('syncLocal:$full'),
      cancelLocalSync: () {
        events.add('syncLocal.cancel');
        return localSync.future;
      },
      cancelBackgroundSync: () {
        events.add('backgroundSync.cancel');
        return websocketSync.future;
      },
      stopBackup: () => events.add('backup.stop'),
      pauseEagerBackup: () async {
        events.add('eager.foreground.stop');
        await foregroundStopped.future;
        events.add('eager.urlSession.start');
      },
      resumeEagerBackup: () => events.add('eager.resume'),
      disconnectWebsocket: () => events.add('websocket.disconnect'),
      lockBackgroundWorker: () async => events.add('worker.lock'),
      unlockBackgroundWorker: () async => events.add('worker.unlock'),
    );

    final pause = work.pause();
    await pumpEventQueue();

    expect(events, ['eager.foreground.stop']);
    foregroundStopped.complete();
    await pumpEventQueue();

    expect(events, [
      'eager.foreground.stop',
      'eager.urlSession.start',
      'coordinator.pause',
      'syncLocal.cancel',
      'backup.stop',
      'websocket.disconnect',
      'backgroundSync.cancel',
    ]);
    reconciliation.complete();
    localSync.complete();
    await pumpEventQueue();
    expect(events, isNot(contains('worker.unlock')));

    websocketSync.complete();
    await pause;

    expect(events.last, 'worker.unlock');
  });
}
