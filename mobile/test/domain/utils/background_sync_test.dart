import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  test('local sync emits error once without also emitting success', () async {
    final runner = _ControlledTaskRunner();
    final events = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      onLocalSyncStart: () => events.add('start'),
      onLocalSyncComplete: () => events.add('success'),
      onLocalSyncError: (_) => events.add('error'),
      onTerminal: (id, operation, terminal) => events.add('$id:${operation.name}:${terminal.name}'),
    );

    final sync = manager.syncLocal();
    runner.task<void>(0).fail(StateError('sync failed'));

    await expectLater(sync, throwsStateError);
    expect(events, ['start', 'error', '1:local:error']);
  });

  test('synchronous remote runner failure emits one error terminal and returns false', () async {
    final events = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: const _ThrowingTaskRunner(),
      onRemoteSyncStart: () => events.add('start'),
      onRemoteSyncComplete: (_) => events.add('success'),
      onRemoteSyncError: (_) => events.add('error'),
      onTerminal: (id, operation, terminal) => events.add('$id:${operation.name}:${terminal.name}'),
    );

    expect(await manager.syncRemote(), isFalse);
    expect(events, ['start', 'error', '1:remote:error']);
  });

  test('synchronous start callback failure still emits one error terminal', () async {
    final events = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: _ControlledTaskRunner(),
      onRemoteSyncStart: () => throw StateError('start failed'),
      onRemoteSyncComplete: (_) => events.add('success'),
      onRemoteSyncError: (_) => events.add('error'),
      onTerminal: (id, operation, terminal) => events.add('$id:${operation.name}:${terminal.name}'),
    );

    expect(await manager.syncRemote(), isFalse);
    expect(events, ['error', '1:remote:error']);
  });

  test('completion callback failure still emits one terminal', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final callbackError = StateError('completion callback failed');
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      onLocalSyncComplete: () => throw callbackError,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final sync = manager.syncLocal();
    runner.task<void>(0).succeed(null);

    await expectLater(sync, throwsA(same(callbackError)));
    expect(terminals, ['1:local:success']);
  });

  test('error callback failure still emits one terminal', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final callbackError = StateError('error callback failed');
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      onLocalSyncError: (_) => throw callbackError,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final sync = manager.syncLocal();
    runner.task<void>(0).fail(StateError('sync failed'));

    await expectLater(sync, throwsA(same(callbackError)));
    expect(terminals, ['1:local:error']);
  });

  test('discarded tap future consumes its failure', () async {
    final uncaught = <Object>[];
    final settled = Completer<void>();

    runZonedGuarded(() {
      consumeBackgroundSyncTap(Future<void>.error(StateError('tap failed')));
      Future<void>.delayed(Duration.zero).then((_) => settled.complete());
    }, (error, _) => uncaught.add(error));

    await settled.future;
    expect(uncaught, isEmpty);
  });

  test('cancellation drains the old local operation before releasing its slot', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final first = manager.syncLocal();
    final firstFailure = expectLater(first, throwsA(isA<CanceledError>()));
    final cancellation = manager.cancelLocal();
    expect(runner.task<void>(0).cancelRequested, isTrue);

    final whileCancelling = manager.syncLocal();
    expect(identical(whileCancelling, first), isTrue);
    expect(runner.tasks, hasLength(1));

    runner.task<void>(0).finishCancellation();
    await cancellation;
    await firstFailure;

    final second = manager.syncLocal();
    expect(runner.tasks, hasLength(2));
    runner.task<void>(1).succeed(null);
    await second;

    expect(terminals, ['1:local:cancelled', '2:local:success']);
  });

  test('websocket cancellation retains its slot until the old task terminates', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final first = manager.syncWebsocketBatch(const []);
    final firstFailure = expectLater(first, throwsA(isA<CanceledError>()));
    final cancellation = manager.cancel();
    expect(runner.task<void>(0).cancelRequested, isTrue);

    expect(identical(manager.syncWebsocketBatch(const []), first), isTrue);
    expect(runner.tasks, hasLength(1));

    runner.task<void>(0).finishCancellation();
    await cancellation;
    await firstFailure;

    final second = manager.syncWebsocketBatch(const []);
    expect(runner.tasks, hasLength(2));
    final secondFailure = expectLater(second, throwsA(isA<CanceledError>()));
    final secondCancellation = manager.cancel();
    expect(runner.task<void>(1).cancelRequested, isTrue);
    runner.task<void>(1).finishCancellation();
    await secondCancellation;
    await secondFailure;

    expect(terminals, ['1:websocket:cancelled', '2:websocket:cancelled']);
  });

  test('linked album cancellation retains its slot until the old task terminates', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final first = manager.syncLinkedAlbum();
    final firstFailure = expectLater(first, throwsA(isA<CanceledError>()));
    final cancellation = manager.cancel();
    expect(runner.task<void>(0).cancelRequested, isTrue);
    expect(identical(manager.syncLinkedAlbum(), first), isTrue);
    expect(runner.tasks, hasLength(1));

    runner.task<void>(0).finishCancellation();
    await cancellation;
    await firstFailure;

    final second = manager.syncLinkedAlbum();
    runner.task<void>(1).succeed(null);
    await second;

    expect(terminals, ['1:linkedAlbums:cancelled', '2:linkedAlbums:success']);
  });
}

final class _ControlledTaskRunner implements BackgroundTaskRunner {
  final tasks = <_ControlledTask<dynamic>>[];

  @override
  Cancelable<T?> start<T>({required Future<T> Function(ProviderContainer ref) computation, String? debugLabel}) {
    final task = _ControlledTask<T>();
    tasks.add(task);
    return task.cancelable;
  }

  _ControlledTask<T> task<T>(int index) => tasks[index] as _ControlledTask<T>;
}

final class _ControlledTask<T> {
  final _completer = Completer<T?>();
  var cancelRequested = false;

  late final cancelable = Cancelable<T?>(completer: _completer, onCancel: () => cancelRequested = true);

  void succeed(T? result) => _completer.complete(result);

  void fail(Object error) => _completer.completeError(error);

  void finishCancellation() => _completer.completeError(CanceledError());
}

final class _ThrowingTaskRunner implements BackgroundTaskRunner {
  const _ThrowingTaskRunner();

  @override
  Cancelable<T?> start<T>({required Future<T> Function(ProviderContainer ref) computation, String? debugLabel}) {
    throw StateError('runner unavailable');
  }
}
