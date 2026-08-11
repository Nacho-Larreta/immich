import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/managed_isolate_worker.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:worker_manager/worker_manager.dart';

void main() {
  late WorkerExecutor executor;

  setUp(() => executor = WorkerExecutor());

  tearDown(() async {
    try {
      await executor.dispose();
    } on PlatformException catch (error) {
      if (!isUnsafeWorkerTermination(error)) rethrow;
    }
  });

  test('concurrent dispose closes admissions and terminal callbacks cannot repopulate workers', () async {
    await executor.init(isolatesCount: 1, dynamicSpawning: false);
    final events = <Object>[];
    final work = executor.executeWithPort<void, Object>(_slowExecutorTask, onMessage: events.add);
    final workFailure = expectLater(work, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');

    final first = executor.dispose();
    final second = executor.dispose();

    expect(() => executor.execute<void>(_emptyExecutorTask), throwsStateError);
    await Future.wait([first, second]);
    await workFailure;
    await Future<void>.delayed(const Duration(milliseconds: 10));
    expect(executor.pool, isEmpty);
    expect(executor.isDisposed, isTrue);
  });

  test('unsafe terminal quarantines its worker and replacement handles future work', () async {
    await executor.init(isolatesCount: 1, dynamicSpawning: false);
    final unsafeWorker = executor.pool.single;

    await expectLater(executor.execute<void>(_unsafeExecutorTask), throwsA(isA<PlatformException>()));
    await _waitForReplacement(executor, unsafeWorker);

    expect(unsafeWorker.isTerminated, isFalse);
    expect(unsafeWorker.isReusable, isFalse);
    await executor.execute<void>(_emptyExecutorTask);
    await expectLater(
      executor.dispose(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', unsafeWorkerTerminationCode)),
    );
  });

  test('dispose includes a quarantined worker previously removed by cancellation', () async {
    await executor.init(isolatesCount: 1, dynamicSpawning: false);
    final events = <Object>[];
    final retired = executor.pool.single;
    final work = executor.executeWithPort<void, Object>(_unsafeAfterCancellation, onMessage: events.add);
    final cancellation = expectLater(work, throwsA(isA<CanceledError>()));
    await _waitFor(events, 'started');

    work.cancel();
    await cancellation;

    await expectLater(
      executor.dispose(),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', unsafeWorkerTerminationCode)),
    );
    expect(retired.isTerminated, isFalse);
    expect(retired.isReusable, isFalse);
  });

  test('dynamic worker stays quiescent while busy and resumes queued admissions on terminal event', () async {
    await executor.init(isolatesCount: 1, dynamicSpawning: true);
    final events = <Object>[];
    final first = executor.executeWithPort<int, Object>(_delayedValueTask, onMessage: events.add);
    await _waitFor(events, 'started');

    final second = executor.execute<int>(_valueTask);
    final eventLoopProgress = Completer<void>();
    Timer.run(eventLoopProgress.complete);

    await eventLoopProgress.future.timeout(const Duration(milliseconds: 100));
    expect(await Future.wait([first, second]), [1, 2]);
  });

  test('quarantine storm blows a bounded fuse and rejects further admissions', () async {
    await executor.init(isolatesCount: 1, dynamicSpawning: false);

    for (var attempt = 0; attempt < 4; attempt++) {
      final retired = executor.pool.single;
      await expectLater(executor.execute<void>(_unsafeExecutorTask), throwsA(isA<PlatformException>()));
      if (attempt < 3) await _waitForReplacement(executor, retired);
    }

    await _waitForQuarantineFuse(executor);
    expect(executor.isQuarantineFuseBlown, isTrue);
    expect(() => executor.execute<void>(_emptyExecutorTask), throwsStateError);
  });

  test('static cancellation waits for retirement terminal before replacing and waking queued work', () async {
    final retirement = Completer<WorkerDisposal>();
    final active = Completer<int>();
    final workers = <_ControlledWorker>[];
    executor = WorkerExecutor(
      workerFactory: () {
        final worker = _ControlledWorker(disposal: workers.isEmpty ? retirement.future : null);
        workers.add(worker);
        return worker;
      },
    );
    await executor.init(isolatesCount: 1, dynamicSpawning: false);
    final first = executor.execute<int>(() => active.future);
    await _waitUntil(() => workers.single.taskId != null);
    final second = executor.execute<int>(() => 2);
    final firstCancellation = expectLater(first, throwsA(isA<CanceledError>()));

    first.cancel();
    await firstCancellation;
    await _waitUntil(() => executor.activeRetirementCount == 1);
    expect(workers, hasLength(1));
    expect(await _staysPending(second), isTrue);

    retirement.complete(WorkerDisposal.terminated);
    expect(await second.timeout(const Duration(milliseconds: 100)), 2);
    expect(workers, hasLength(2));
  });

  test('two dynamic admissions behind one initializing worker yield the event loop and both terminate', () async {
    final initialization = Completer<void>();
    final workers = <_ControlledWorker>[];
    executor = WorkerExecutor(
      workerFactory: () {
        final worker = _ControlledWorker(initialization: initialization.future);
        workers.add(worker);
        return worker;
      },
    );
    await executor.init(isolatesCount: 1, dynamicSpawning: true);

    final first = executor.execute<int>(() => 1);
    final second = executor.execute<int>(() => 2);
    final eventLoopProgress = Completer<void>();
    Timer.run(eventLoopProgress.complete);

    await eventLoopProgress.future.timeout(const Duration(milliseconds: 100));
    expect(workers, hasLength(1));
    expect(await _staysPending(first), isTrue);
    expect(await _staysPending(second), isTrue);
    initialization.complete();
    expect(await Future.wait([first, second]).timeout(const Duration(milliseconds: 100)), [1, 2]);
  });

  test('dynamic admission cannot respawn until the prior worker retirement terminates', () async {
    final retirement = Completer<WorkerDisposal>();
    final workers = <_ControlledWorker>[];
    executor = WorkerExecutor(
      workerFactory: () {
        final worker = _ControlledWorker(disposal: workers.isEmpty ? retirement.future : null);
        workers.add(worker);
        return worker;
      },
    );
    await executor.init(isolatesCount: 1, dynamicSpawning: true);
    expect(await executor.execute<int>(() => 1), 1);
    await _waitUntil(() => executor.activeRetirementCount == 1);

    final second = executor.execute<int>(() => 2);
    expect(workers, hasLength(1));
    expect(await _staysPending(second), isTrue);
    retirement.complete(WorkerDisposal.terminated);

    expect(await second.timeout(const Duration(milliseconds: 100)), 2);
    expect(workers, hasLength(2));
  });

  test('retirement capacity is reserved synchronously and quarantine fuse survives dispose and reinit', () async {
    final retirements = [Completer<WorkerDisposal>(), Completer<WorkerDisposal>()];
    final active = [Completer<int>(), Completer<int>()];
    var nextRetirement = 0;
    executor = WorkerExecutor(
      quarantineCapacity: 2,
      workerFactory: () => _ControlledWorker(disposal: retirements[nextRetirement++].future),
    );
    await executor.init(isolatesCount: 2, dynamicSpawning: false);
    final first = executor.execute<int>(() => active[0].future);
    final second = executor.execute<int>(() => active[1].future);
    await _waitUntil(() => executor.pool.every((worker) => worker.taskId != null));
    final firstCancellation = expectLater(first, throwsA(isA<CanceledError>()));
    final secondCancellation = expectLater(second, throwsA(isA<CanceledError>()));

    first.cancel();
    second.cancel();
    await Future.wait([firstCancellation, secondCancellation]);
    expect(executor.pool, isEmpty);
    expect(executor.activeRetirementCount, 2);
    expect(nextRetirement, 2);

    for (final retirement in retirements) {
      retirement.complete(WorkerDisposal.quarantined);
    }
    await _waitForQuarantineFuse(executor);
    expect(executor.retainedQuarantineCount, 2);
    await expectLater(executor.dispose(), throwsA(isA<PlatformException>()));
    await expectLater(executor.init(isolatesCount: 1), throwsStateError);
    expect(() => executor.execute<int>(() => 3), throwsStateError);
  });
}

Future<void> _slowExecutorTask(SendPort port) async {
  port.send('started');
  await Future<void>.delayed(const Duration(milliseconds: 100));
}

Future<void> _emptyExecutorTask() async {}

Future<int> _valueTask() async => 2;

Future<int> _delayedValueTask(SendPort port) async {
  port.send('started');
  await Future<void>.delayed(const Duration(milliseconds: 30));
  return 1;
}

Future<void> _unsafeExecutorTask() async {
  throw PlatformException(code: unsafeWorkerTerminationCode);
}

Future<void> _unsafeAfterCancellation(SendPort port) async {
  port.send('started');
  await Future<void>.delayed(const Duration(milliseconds: 20));
  throw PlatformException(code: unsafeWorkerTerminationCode);
}

Future<void> _waitForReplacement(WorkerExecutor executor, Object retired) async {
  while (executor.pool.isEmpty || identical(executor.pool.single, retired) || !executor.pool.single.isReusable) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _waitFor(List<Object> events, Object expected) async {
  while (!events.contains(expected)) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _waitForQuarantineFuse(WorkerExecutor executor) async {
  while (!executor.isQuarantineFuseBlown) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<void> _waitUntil(bool Function() predicate) async {
  while (!predicate()) {
    await Future<void>.delayed(const Duration(milliseconds: 1));
  }
}

Future<bool> _staysPending(Future<Object?> future) async {
  final terminal = Completer<void>();
  unawaited(future.then<void>((_) => terminal.complete(), onError: (_, __) => terminal.complete()));
  await Future.any([terminal.future, Future<void>.delayed(const Duration(milliseconds: 10))]);
  return !terminal.isCompleted;
}

final class _ControlledWorker implements IsolateWorker {
  _ControlledWorker({Future<void>? initialization, Future<WorkerDisposal>? disposal})
    : _initializationGate = initialization,
      _disposalGate = disposal;

  final Future<void>? _initializationGate;
  final Future<WorkerDisposal>? _disposalGate;
  bool _initialized = false;
  bool _initializing = false;
  bool _acceptingWork = true;
  bool _terminated = false;
  String? _taskId;

  @override
  bool get initialized => _initialized;

  @override
  bool get initializing => _initializing;

  @override
  bool get isReusable => _initialized && _acceptingWork && !_terminated && _taskId == null;

  @override
  bool get isTerminated => _terminated;

  @override
  String? get taskId => _taskId;

  @override
  Future<void> initialize() async {
    _initializing = true;
    await _initializationGate;
    _initializing = false;
    if (!_terminated) _initialized = true;
  }

  @override
  Future<R> work<R>(Task<R> task) async {
    if (!isReusable) throw StateError('Controlled worker is unavailable');
    _taskId = task.id;
    try {
      final execution = task.execution;
      if (execution is Execute<R>) return await execution();
      if (execution is ExecuteGentle<R>) return await execution(() => task.canceled);
      throw StateError('Unsupported controlled task');
    } finally {
      _taskId = null;
    }
  }

  @override
  void requestGentleCancellation() {}

  @override
  Future<WorkerDisposal> dispose({Duration drainTimeout = const Duration(seconds: 5)}) async {
    _acceptingWork = false;
    final disposal = await (_disposalGate ?? Future.value(WorkerDisposal.terminated));
    if (disposal == WorkerDisposal.terminated) _terminated = true;
    return disposal;
  }
}
