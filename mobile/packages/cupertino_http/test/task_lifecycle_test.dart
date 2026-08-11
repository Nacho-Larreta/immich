import 'dart:async';

import 'package:cupertino_http/src/streaming_task_lifecycle.dart';
import 'package:test/test.dart';

void main() {
  test(
    'cancel waits for didComplete and invokes native cancellation once',
    () async {
      final lifecycle = StreamingTaskLifecycle();
      var cancelCalls = 0;

      final first = lifecycle.cancelAndWait(() => cancelCalls++);
      final second = lifecycle.cancelAndWait(() => cancelCalls++);
      var completed = false;
      unawaited(first.then((_) => completed = true));

      await Future<void>.delayed(Duration.zero);
      expect(cancelCalls, 1);
      expect(completed, isFalse);

      lifecycle.didComplete();
      await Future.wait([first, second]);
      expect(completed, isTrue);
    },
  );

  for (final stage in ['before headers', 'during body']) {
    test('cancel $stage remains pending until native didComplete', () async {
      final lifecycle = StreamingTaskLifecycle();
      final terminal = lifecycle.cancelAndWait(() {});
      var completed = false;
      unawaited(terminal.then((_) => completed = true));

      await Future<void>.delayed(Duration.zero);
      expect(completed, isFalse);

      lifecycle.didComplete();
      await terminal;
      expect(completed, isTrue);
    });
  }

  test(
    'didComplete winning the cancellation race does not cancel a terminal task',
    () async {
      final lifecycle = StreamingTaskLifecycle()..didComplete();
      var cancelCalls = 0;

      await lifecycle.cancelAndWait(() => cancelCalls++);

      expect(cancelCalls, 0);
    },
  );

  test(
    'client A close drains only A while shared-session client B remains active',
    () async {
      final firstOwner = OwnedStreamingTasks<_FakeTask>(
        cancelAndWait: (task) => task.cancelAndWait(),
        completed: (task) => task.completed,
      );
      final secondOwner = OwnedStreamingTasks<_FakeTask>(
        cancelAndWait: (task) => task.cancelAndWait(),
        completed: (task) => task.completed,
      );
      final firstTask = _FakeTask();
      final secondTask = _FakeTask();
      firstOwner.admit(firstTask);
      secondOwner.admit(secondTask);

      final firstDrain = firstOwner.closeAndDrain();
      await Future<void>.delayed(Duration.zero);

      expect(firstTask.cancelCalls, 1);
      expect(secondTask.cancelCalls, 0);
      expect(firstOwner.isDrained, isFalse);

      firstTask.complete();
      await firstDrain;
      expect(firstOwner.isDrained, isTrue);
      expect(secondOwner.activeCount, 1);
    },
  );

  test('admission after close is rejected before task start', () {
    final owner = OwnedStreamingTasks<_FakeTask>(
      cancelAndWait: (_FakeTask task) => task.cancelAndWait(),
      completed: (_FakeTask task) => task.completed,
    );
    final task = _FakeTask();
    unawaited(owner.closeAndDrain());

    expect(owner.admit(task), isFalse);
    expect(task.cancelCalls, 0);
  });

  test(
    'iOS 14 buffered close waits for completion and leaves client B active',
    () async {
      final firstOwner = OwnedStreamingTasks<_FakeTask>(
        cancelAndWait: (_FakeTask task) => task.cancelAndWait(),
        completed: (_FakeTask task) => task.completed,
      );
      final secondOwner = OwnedStreamingTasks<_FakeTask>(
        cancelAndWait: (_FakeTask task) => task.cancelAndWait(),
        completed: (_FakeTask task) => task.completed,
      );
      final firstTask = _FakeTask();
      final secondTask = _FakeTask();
      firstOwner.admit(firstTask);
      secondOwner.admit(secondTask);

      final close = firstOwner.closeAndDrain();
      final repeatedClose = firstOwner.closeAndDrain();
      var closed = false;
      unawaited(close.then((_) => closed = true));
      await Future<void>.delayed(Duration.zero);

      expect(firstTask.cancelCalls, 1);
      expect(repeatedClose, same(close));
      expect(secondTask.cancelCalls, 0);
      expect(closed, isFalse);

      firstTask.complete();
      await close;
      expect(closed, isTrue);
      expect(secondOwner.activeCount, 1);
    },
  );

  test(
    'rejected buffered task waits for native terminal and callback settlement',
    () async {
      final lifecycle = StreamingTaskLifecycle();
      final callbackSettlement = Completer<void>();
      var cancelCalls = 0;
      var rejected = false;

      final rejection = cancelRejectedTaskAndWait(
        cancelAndWait: () => lifecycle.cancelAndWait(() => cancelCalls++),
        callbackSettlement: callbackSettlement.future,
      );
      unawaited(rejection.then((_) => rejected = true));

      await Future<void>.delayed(Duration.zero);
      expect(cancelCalls, 1);
      expect(rejected, isFalse);

      lifecycle.didComplete();
      await Future<void>.delayed(Duration.zero);
      expect(rejected, isFalse);

      callbackSettlement.complete();
      await rejection;
      expect(rejected, isTrue);
    },
  );
}

final class _FakeTask {
  final _terminal = Completer<void>();
  int cancelCalls = 0;

  Future<void> get completed => _terminal.future;

  Future<void> cancelAndWait() {
    cancelCalls++;
    return completed;
  }

  void complete() => _terminal.complete();
}
