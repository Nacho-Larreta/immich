// part of 'package:worker_manager/worker_manager.dart';
// ignore_for_file: implementation_imports, avoid_print

import 'dart:async';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/managed_isolate_worker.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:worker_manager/src/number_of_processors/processors_io.dart';
import 'package:worker_manager/worker_manager.dart';

final workerManagerPatch = _Executor();

// [-2^54; 2^53] is compatible with dart2js, see core.int doc
const _minId = -9007199254740992;
const _maxId = 9007199254740992;

class Mixinable<T> {
  late final itSelf = this as T;
}

mixin _ExecutorLogger on Mixinable<_Executor> {
  var log = false;

  @mustCallSuper
  void init() {
    logMessage("${itSelf._isolatesCount} workers have been spawned and initialized");
  }

  void logTaskAdded<R>(String uid) {
    logMessage("added task with number $uid");
  }

  @mustCallSuper
  void dispose() {
    logMessage("worker_manager have been disposed");
  }

  @mustCallSuper
  void _cancel(Task task) {
    logMessage("Task ${task.id} have been canceled");
  }

  void logMessage(String message) {
    if (log) print(message);
  }
}

class _Executor extends Mixinable<_Executor> with _ExecutorLogger {
  final _queue = PriorityQueue<Task>();
  final _pool = <ManagedIsolateWorker>[];
  final _retirements = <Future<WorkerDisposal>>{};
  var _nextTaskId = _minId;
  var _dynamicSpawning = false;
  var _isolatesCount = numberOfProcessors;
  var _generation = 0;
  var _disposing = false;
  var _disposed = false;
  var _hasQuarantinedRetirement = false;
  Future<void>? _disposal;

  @visibleForTesting
  UnmodifiableListView<ManagedIsolateWorker> get pool => UnmodifiableListView(_pool);
  @visibleForTesting
  bool get isDisposed => _disposed;

  bool get _acceptingWork => !_disposing && !_disposed;

  @override
  Future<void> init({int? isolatesCount, bool? dynamicSpawning}) async {
    if (_disposing) {
      throw StateError('worker_manager is disposing');
    }
    if (_pool.isNotEmpty) {
      print("worker_manager already warmed up, init is ignored. Dispose before init");
      return;
    }
    if (_disposed) {
      _disposed = false;
      _disposal = null;
      _hasQuarantinedRetirement = false;
      _generation++;
    }
    if (isolatesCount != null) {
      if (isolatesCount < 0) {
        throw Exception("isolatesCount must be greater than 0");
      }

      _isolatesCount = isolatesCount;
    }
    _dynamicSpawning = dynamicSpawning ?? false;
    await _ensureWorkersInitialized(_generation);
    super.init();
  }

  @override
  Future<void> dispose() {
    super.dispose();
    return _disposal ??= _dispose();
  }

  Future<void> _dispose() async {
    _disposing = true;
    _generation++;
    while (_queue.isNotEmpty) {
      _queue.removeFirst().cancel();
    }
    final workers = _pool.toList(growable: false);
    _pool.clear();
    for (final worker in workers) {
      unawaited(_retireWorker(worker));
    }
    await Future.wait(_retirements.toList(growable: false));
    _disposing = false;
    _disposed = true;
    if (_hasQuarantinedRetirement) {
      throw PlatformException(code: unsafeWorkerTerminationCode, message: unsafeWorkerTerminationCode);
    }
  }

  Cancelable<R> execute<R>(Execute<R> execution, {WorkPriority priority = WorkPriority.immediately}) {
    return _createCancelable<R>(execution: execution, priority: priority);
  }

  Cancelable<R> executeNow<R>(ExecuteGentle<R> execution) {
    _ensureAcceptingWork();
    final task = TaskGentle<R>(
      id: "",
      workPriority: WorkPriority.immediately,
      execution: execution,
      completer: Completer<R>(),
    );

    Future<void> run() async {
      try {
        final result = await execution(() => task.canceled);
        task.complete(result, null, null);
      } catch (error, st) {
        task.complete(null, error, st);
      }
    }

    run();
    return Cancelable(completer: task.completer, onCancel: () => _cancel(task));
  }

  Cancelable<R> executeWithPort<R, T>(
    ExecuteWithPort<R> execution, {
    WorkPriority priority = WorkPriority.immediately,
    required void Function(T value) onMessage,
  }) {
    return _createCancelable<R>(
      execution: execution,
      priority: priority,
      onMessage: (message) => onMessage(message as T),
    );
  }

  Cancelable<R> executeGentle<R>(ExecuteGentle<R> execution, {WorkPriority priority = WorkPriority.immediately}) {
    return _createCancelable<R>(execution: execution, priority: priority);
  }

  Cancelable<R> executeGentleWithPort<R, T>(
    ExecuteGentleWithPort<R> execution, {
    WorkPriority priority = WorkPriority.immediately,
    required void Function(T value) onMessage,
  }) {
    return _createCancelable<R>(
      execution: execution,
      priority: priority,
      onMessage: (message) => onMessage(message as T),
    );
  }

  void _createWorkers(int generation) {
    if (!_isActiveGeneration(generation)) return;
    for (var i = 0; i < _isolatesCount; i++) {
      _pool.add(ManagedIsolateWorker());
    }
  }

  Future<void> _initializeWorkers() async {
    await Future.wait(_pool.map((e) => e.initialize()));
  }

  Cancelable<R> _createCancelable<R>({
    required Function execution,
    WorkPriority priority = WorkPriority.immediately,
    void Function(Object value)? onMessage,
  }) {
    _ensureAcceptingWork();
    if (_nextTaskId + 1 == _maxId) {
      _nextTaskId = _minId;
    }
    final id = _nextTaskId.toString();
    _nextTaskId++;
    late final Task<R> task;
    final completer = Completer<R>();
    if (execution is ExecuteWithPort<R>) {
      task = TaskWithPort<R>(
        id: id,
        workPriority: priority,
        execution: execution,
        completer: completer,
        onMessage: onMessage!,
      );
    } else if (execution is ExecuteGentle<R>) {
      task = TaskGentle<R>(id: id, workPriority: priority, execution: execution, completer: completer);
    } else if (execution is ExecuteGentleWithPort<R>) {
      task = TaskGentleWithPort<R>(
        id: id,
        workPriority: priority,
        execution: execution,
        completer: completer,
        onMessage: onMessage!,
      );
    } else if (execution is Execute<R>) {
      task = TaskRegular<R>(id: id, workPriority: priority, execution: execution, completer: completer);
    }
    _queue.add(task);
    _schedule();
    logTaskAdded(task.id);
    return Cancelable(completer: task.completer, onCancel: () => _cancel(task));
  }

  Future<void> _ensureWorkersInitialized(int generation) async {
    if (!_isActiveGeneration(generation)) return;
    if (_pool.isEmpty) {
      _createWorkers(generation);
      if (!_dynamicSpawning) {
        await _initializeWorkers();
        if (!_isActiveGeneration(generation)) return;
        final poolSize = _pool.length;
        final queueSize = _queue.length;
        for (int i = 0; i <= min(poolSize, queueSize); i++) {
          _schedule();
        }
      }
    }
    if (_pool.every((worker) => worker.taskId != null)) {
      return;
    }
    if (_dynamicSpawning && _queue.isNotEmpty) {
      final freeWorker = _pool.firstWhereOrNull(
        (worker) => worker.taskId == null && !worker.initialized && !worker.initializing,
      );
      await freeWorker?.initialize();
      if (_isActiveGeneration(generation)) _schedule();
    }
  }

  void _schedule() {
    if (!_acceptingWork) return;
    final generation = _generation;
    final availableWorker = _pool.firstWhereOrNull((worker) => worker.isReusable);
    if (availableWorker == null) {
      unawaited(_ensureWorkersInitialized(generation));
      return;
    }
    if (_queue.isEmpty) return;
    final task = _queue.removeFirst();

    availableWorker
        .work(task)
        .then(
          (value) {
            task.complete(value, null, null);
          },
          onError: (error, st) {
            task.complete(null, error, st);
          },
        )
        .whenComplete(() async {
          if (!_isActiveGeneration(generation)) return;
          if (!availableWorker.isReusable && _pool.contains(availableWorker)) {
            _pool.remove(availableWorker);
            await _retireWorker(availableWorker);
            if (!_dynamicSpawning && _isActiveGeneration(generation)) {
              final replacement = ManagedIsolateWorker();
              _pool.add(replacement);
              await replacement.initialize();
            }
          } else if (_dynamicSpawning && _queue.isEmpty && _pool.remove(availableWorker)) {
            await _retireWorker(availableWorker);
          }
          if (_isActiveGeneration(generation)) _schedule();
        });
  }

  @override
  void _cancel(Task task) {
    task.cancel();
    _queue.remove(task);
    final targetWorker = _pool.firstWhereOrNull((worker) => worker.taskId == task.id);
    if (task is Gentle) {
      targetWorker?.requestGentleCancellation();
    } else {
      if (targetWorker != null) {
        _pool.remove(targetWorker);
        _retireWorker(targetWorker);
        if (!_dynamicSpawning) {
          final replacement = ManagedIsolateWorker();
          _pool.add(replacement);
          final generation = _generation;
          unawaited(
            replacement.initialize().whenComplete(() {
              if (_isActiveGeneration(generation)) _schedule();
            }),
          );
        }
      }
    }
    super._cancel(task);
  }

  bool _isActiveGeneration(int generation) => _acceptingWork && generation == _generation;

  Future<WorkerDisposal> _retireWorker(ManagedIsolateWorker worker) {
    late final Future<WorkerDisposal> retirement;
    retirement = _disposeWorker(worker);
    _retirements.add(retirement);
    unawaited(
      retirement.then<void>((_) {
        _retirements.remove(retirement);
      }),
    );
    return retirement;
  }

  Future<WorkerDisposal> _disposeWorker(ManagedIsolateWorker worker) async {
    try {
      final disposal = await worker.dispose();
      if (disposal == WorkerDisposal.quarantined) {
        _hasQuarantinedRetirement = true;
      }
      return disposal;
    } on Object {
      _hasQuarantinedRetirement = true;
      return WorkerDisposal.quarantined;
    }
  }

  void _ensureAcceptingWork() {
    if (!_acceptingWork) {
      throw StateError('worker_manager is not accepting work');
    }
  }
}
