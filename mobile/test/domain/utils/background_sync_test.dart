import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/background_task_runner.interface.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/background_task.model.dart';
import 'package:immich_mobile/domain/utils/background_sync.dart';

void main() {
  test('domain background sync has no ProviderContainer, worker, or infrastructure imports', () {
    final source = File('lib/domain/utils/background_sync.dart').readAsStringSync();

    expect(source, isNot(contains('ProviderContainer')));
    expect(source, isNot(contains('worker_manager')));
    expect(source, isNot(contains('/providers/')));
    expect(source, isNot(contains('/infrastructure/')));
    expect(source, isNot(contains('IsolateBackgroundTaskRunner')));
  });

  test('local sync emits error once without also emitting success', () async {
    final runner = _ControlledTaskRunner();
    final events = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      remoteTaskContext: _testRemoteTaskContext,
      onLocalSyncStart: () => events.add('start'),
      onLocalSyncComplete: () => events.add('success'),
      onLocalSyncError: (_) => events.add('error'),
      onTerminal: (id, operation, terminal) => events.add('$id:${operation.name}:${terminal.name}'),
    );

    final sync = manager.syncLocal();
    runner.task(0).fail(StateError('sync failed'));

    await expectLater(sync, throwsStateError);
    expect(events, ['start', 'error', '1:local:error']);
  });

  test('synchronous remote runner failure emits one error terminal and returns false', () async {
    final events = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: const _ThrowingTaskRunner(),
      remoteTaskContext: _testRemoteTaskContext,
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
      remoteTaskContext: _testRemoteTaskContext,
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
      remoteTaskContext: _testRemoteTaskContext,
      onLocalSyncComplete: () => throw callbackError,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final sync = manager.syncLocal();
    runner.task(0).succeed(null);

    await expectLater(sync, throwsA(same(callbackError)));
    expect(terminals, ['1:local:success']);
  });

  test('error callback failure still emits one terminal', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final callbackError = StateError('error callback failed');
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      remoteTaskContext: _testRemoteTaskContext,
      onLocalSyncError: (_) => throw callbackError,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final sync = manager.syncLocal();
    runner.task(0).fail(StateError('sync failed'));

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
      remoteTaskContext: _testRemoteTaskContext,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final first = manager.syncLocal();
    final firstFailure = expectLater(first, throwsA(isA<BackgroundTaskCancelled>()));
    final cancellation = manager.cancelLocal();
    expect(runner.task(0).cancelRequested, isTrue);

    final whileCancelling = manager.syncLocal();
    expect(identical(whileCancelling, first), isTrue);
    expect(runner.tasks, hasLength(1));

    runner.task(0).finishCancellation();
    await cancellation;
    await firstFailure;

    final second = manager.syncLocal();
    expect(runner.tasks, hasLength(2));
    runner.task(1).succeed(null);
    await second;

    expect(terminals, ['1:local:cancelled', '2:local:success']);
  });

  test('websocket cancellation retains its slot until the old task terminates', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      remoteTaskContext: _testRemoteTaskContext,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final first = manager.syncWebsocketBatch(const []);
    final firstFailure = expectLater(first, throwsA(isA<BackgroundTaskCancelled>()));
    final cancellation = manager.cancel();
    expect(runner.task(0).cancelRequested, isTrue);

    expect(identical(manager.syncWebsocketBatch(const []), first), isTrue);
    expect(runner.tasks, hasLength(1));

    runner.task(0).finishCancellation();
    await cancellation;
    await firstFailure;

    final second = manager.syncWebsocketBatch(const []);
    expect(runner.tasks, hasLength(2));
    final secondFailure = expectLater(second, throwsA(isA<BackgroundTaskCancelled>()));
    final secondCancellation = manager.cancel();
    expect(runner.task(1).cancelRequested, isTrue);
    runner.task(1).finishCancellation();
    await secondCancellation;
    await secondFailure;

    expect(terminals, ['1:websocket:cancelled', '2:websocket:cancelled']);
  });

  test('linked album cancellation retains its slot until the old task terminates', () async {
    final runner = _ControlledTaskRunner();
    final terminals = <String>[];
    final manager = BackgroundSyncManager(
      taskRunner: runner,
      remoteTaskContext: _testRemoteTaskContext,
      onTerminal: (id, operation, terminal) => terminals.add('$id:${operation.name}:${terminal.name}'),
    );

    final first = manager.syncLinkedAlbum();
    final firstFailure = expectLater(first, throwsA(isA<BackgroundTaskCancelled>()));
    final cancellation = manager.cancel();
    expect(runner.task(0).cancelRequested, isTrue);
    expect(identical(manager.syncLinkedAlbum(), first), isTrue);
    expect(runner.tasks, hasLength(1));

    runner.task(0).finishCancellation();
    await cancellation;
    await firstFailure;

    final second = manager.syncLinkedAlbum();
    runner.task(1).succeed(null);
    await second;

    expect(terminals, ['1:linkedAlbums:cancelled', '2:linkedAlbums:success']);
  });
}

const _testBackgroundContext = BackgroundTaskContextBinding(sessionEpoch: 1, nativeContextGeneration: 1);

BackgroundTaskContextBinding _testRemoteTaskContext() => _testBackgroundContext;

final class _ControlledTaskRunner implements BackgroundTaskRunner {
  final tasks = <_ControlledTask>[];

  @override
  CancellableRequest<Object?> start({required BackgroundTaskDescriptor task, String? debugLabel}) {
    final controlled = _ControlledTask();
    tasks.add(controlled);
    return controlled.cancelable;
  }

  _ControlledTask task(int index) => tasks[index];
}

final class _ControlledTask {
  final _completer = Completer<Object?>();
  var cancelRequested = false;

  late final cancelable = _ControlledCancellableRequest(_completer, () => cancelRequested = true);

  void succeed(Object? result) => _completer.complete(result);

  void fail(Object error) => _completer.completeError(error);

  void finishCancellation() => _completer.completeError(const BackgroundTaskCancelled());
}

final class _ControlledCancellableRequest implements CancellableRequest<Object?> {
  const _ControlledCancellableRequest(this._completer, this._onCancel);

  final Completer<Object?> _completer;
  final void Function() _onCancel;

  @override
  Future<Object?> get result => _completer.future;

  @override
  Future<void> cancel() async => _onCancel();
}

final class _ThrowingTaskRunner implements BackgroundTaskRunner {
  const _ThrowingTaskRunner();

  @override
  CancellableRequest<Object?> start({required BackgroundTaskDescriptor task, String? debugLabel}) {
    throw StateError('runner unavailable');
  }
}
