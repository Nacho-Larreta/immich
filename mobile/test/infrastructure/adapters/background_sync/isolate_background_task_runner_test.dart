import 'dart:isolate';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/background_task.model.dart';
import 'package:immich_mobile/infrastructure/adapters/background_sync/isolate_background_task_runner.dart';

void main() {
  test('adapter sends its top-level dispatch tear-off and every immutable task through a real isolate', () async {
    const binding = BackgroundTaskContextBinding(sessionEpoch: 4, nativeContextGeneration: 7);
    final tasks = [
      const BackgroundTaskDescriptor.localSync(full: false),
      const BackgroundTaskDescriptor.localSync(full: true),
      const BackgroundTaskDescriptor.hashAssets(),
      const BackgroundTaskDescriptor.remoteSync().boundTo(binding),
      const BackgroundTaskDescriptor.cloudIds().boundTo(binding),
      const BackgroundTaskDescriptor.linkedAlbums().boundTo(binding),
      BackgroundTaskDescriptor.websocketBatch(<Object?>[]).boundTo(binding),
      BackgroundTaskDescriptor.websocketEdit(<String, Object?>{}).boundTo(binding),
    ];

    for (final task in tasks) {
      final result = await Isolate.run(() => (dispatch: executeBackgroundTask, task: task));
      expect(result.dispatch, executeBackgroundTask);
      expect(result.task, task);
    }
  });

  test('delayed session A task fails closed before remote provider dispatch after session B activates', () async {
    const sessionA = BackgroundTaskContextBinding(sessionEpoch: 2, nativeContextGeneration: 7);
    final queuedTask = const BackgroundTaskDescriptor.remoteSync().boundTo(sessionA);
    var remoteDispatches = 0;

    await expectLater(
      executeBackgroundTaskWhenCurrent(
        task: queuedTask,
        currentContext: const BackgroundTaskContextBinding(sessionEpoch: 3, nativeContextGeneration: 8),
        dispatch: () async {
          remoteDispatches++;
          return null;
        },
      ),
      throwsA(isA<BackgroundTaskContextChanged>()),
    );

    expect(remoteDispatches, 0);
  });

  test('delayed session A task fails closed when session B reuses the native generation', () async {
    const sessionA = BackgroundTaskContextBinding(sessionEpoch: 2, nativeContextGeneration: 7);
    final queuedTask = const BackgroundTaskDescriptor.remoteSync().boundTo(sessionA);
    var remoteDispatches = 0;

    await expectLater(
      executeBackgroundTaskWhenCurrent(
        task: queuedTask,
        currentContext: const BackgroundTaskContextBinding(sessionEpoch: 3, nativeContextGeneration: 7),
        dispatch: () async {
          remoteDispatches++;
          return null;
        },
      ),
      throwsA(isA<BackgroundTaskContextChanged>()),
    );

    expect(remoteDispatches, 0);
  });

  test('remote task runs only when session epoch and native generation both match', () async {
    const current = BackgroundTaskContextBinding(sessionEpoch: 3, nativeContextGeneration: 7);
    final queuedTask = const BackgroundTaskDescriptor.remoteSync().boundTo(current);
    var remoteDispatches = 0;

    await executeBackgroundTaskWhenCurrent(
      task: queuedTask,
      currentContext: current,
      dispatch: () async {
        remoteDispatches++;
        return null;
      },
    );

    expect(remoteDispatches, 1);
  });

  test('local-only task remains runnable without a server context binding', () async {
    var localDispatches = 0;

    await executeBackgroundTaskWhenCurrent(
      task: const BackgroundTaskDescriptor.localSync(full: false),
      currentContext: const BackgroundTaskContextBinding(sessionEpoch: 9, nativeContextGeneration: 8),
      dispatch: () async {
        localDispatches++;
        return null;
      },
    );

    expect(localDispatches, 1);
  });
}
