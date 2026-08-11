import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:collection/collection.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/utils/managed_isolate_worker.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:logging/logging.dart';
import 'package:worker_manager/worker_manager.dart';

final workerManagerPatch = WorkerExecutor();

// [-2^54; 2^53] is compatible with dart2js, see core.int doc
const _minId = -9007199254740992;
const _maxId = 9007199254740992;

typedef IsolateWorkerFactory = IsolateWorker Function();

final class WorkerExecutor {
  WorkerExecutor({IsolateWorkerFactory workerFactory = ManagedIsolateWorker.new, int? quarantineCapacity})
    : _workerFactory = workerFactory,
      _configuredQuarantineCapacity = quarantineCapacity {
    if (quarantineCapacity != null && quarantineCapacity < 1) {
      throw ArgumentError.value(quarantineCapacity, 'quarantineCapacity', 'Must be positive');
    }
  }

  static final _log = Logger('WorkerExecutor');
  static const _maximumInitializationFailures = 3;

  final _queue = PriorityQueue<Task>();
  final IsolateWorkerFactory _workerFactory;
  final int? _configuredQuarantineCapacity;
  final _pool = <IsolateWorker>[];
  final _retirements = <Future<WorkerDisposal>>{};
  var _nextTaskId = _minId;
  var _dynamicSpawning = false;
  var _isolatesCount = max(Platform.numberOfProcessors - 1, 1);
  var _generation = 0;
  var _disposing = false;
  var _disposed = false;
  var _hasQuarantinedRetirement = false;
  var _quarantinedRetirementCount = 0;
  var _activeRetirementCount = 0;
  var _consecutiveInitializationFailures = 0;
  var _quarantineFuseBlown = false;
  Future<void>? _disposal;
  Future<void>? _workerInitialization;

  @visibleForTesting
  UnmodifiableListView<IsolateWorker> get pool => UnmodifiableListView(_pool);
  @visibleForTesting
  bool get isDisposed => _disposed;
  @visibleForTesting
  bool get isQuarantineFuseBlown => _quarantineFuseBlown;
  @visibleForTesting
  int get activeRetirementCount => _activeRetirementCount;
  @visibleForTesting
  int get retainedQuarantineCount => _quarantinedRetirementCount;

  bool get _acceptingWork => !_disposing && !_disposed;

  Future<void> init({int? isolatesCount, bool? dynamicSpawning}) async {
    if (_disposing) {
      throw StateError('worker_manager is disposing');
    }
    if (_quarantineFuseBlown) {
      throw StateError('worker_manager quarantine fuse is blown');
    }
    if (_pool.isNotEmpty) {
      _log.fine('Worker executor already initialized');
      return;
    }
    if (_disposed) {
      _disposed = false;
      _disposal = null;
      _consecutiveInitializationFailures = 0;
      _generation++;
    }
    if (isolatesCount != null) {
      if (isolatesCount < 0) {
        throw ArgumentError.value(isolatesCount, 'isolatesCount', 'Must not be negative');
      }

      _isolatesCount = isolatesCount;
    }
    _updateQuarantineFuse();
    if (_quarantineFuseBlown) {
      throw StateError('worker_manager quarantine fuse is blown');
    }
    _dynamicSpawning = dynamicSpawning ?? false;
    await _ensureWorkersInitialized(_generation);
    _log.fine('Worker executor initialized workers=$_isolatesCount dynamic=$_dynamicSpawning');
  }

  Future<void> dispose() {
    _log.fine('Worker executor disposal requested');
    return _disposal ??= _dispose();
  }

  Future<void> _dispose() async {
    _disposing = true;
    _generation++;
    _workerInitialization = null;
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
    if (!_isActiveGeneration(generation) || _activeRetirementCount > 0 || _quarantineFuseBlown) return;
    final availableCapacity = _workerCapacity - _capacityInUse;
    final targetCount = min(_isolatesCount - _pool.length, availableCapacity);
    for (var i = 0; i < targetCount; i++) {
      _pool.add(_workerFactory());
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
    _log.finer('Worker task admitted');
    return Cancelable(completer: task.completer, onCancel: () => _cancel(task));
  }

  Future<void> _ensureWorkersInitialized(int generation) async {
    if (!_isActiveGeneration(generation)) return;
    if (_pool.isEmpty) {
      _createWorkers(generation);
      if (!_dynamicSpawning) {
        try {
          await _initializeWorkers();
        } on Object catch (error, stackTrace) {
          _failQueued(error, stackTrace);
          rethrow;
        }
        if (!_isActiveGeneration(generation)) return;
        _schedule();
      }
    }
    if (_dynamicSpawning && _queue.isNotEmpty) _requestWorkerInitialization(generation);
  }

  void _schedule() {
    if (!_acceptingWork || _quarantineFuseBlown || _queue.isEmpty) return;
    final generation = _generation;
    while (_queue.isNotEmpty) {
      final availableWorker = _pool.firstWhereOrNull((worker) => worker.isReusable);
      if (availableWorker == null) break;
      _dispatchToWorker(availableWorker, _queue.removeFirst(), generation);
    }
    if (_queue.isNotEmpty) _requestWorkerInitialization(generation);
  }

  void _dispatchToWorker(IsolateWorker worker, Task task, int generation) {
    unawaited(
      worker
          .work(task)
          .then(
            (value) {
              task.complete(value, null, null);
            },
            onError: (error, st) {
              task.complete(null, error, st);
            },
          )
          .whenComplete(() => _handleWorkTerminal(worker, generation))
          .catchError((Object _, StackTrace __) {
            _log.warning('Worker terminal handling failed');
          }),
    );
  }

  Future<void> _handleWorkTerminal(IsolateWorker worker, int generation) async {
    if (!_isActiveGeneration(generation)) return;
    if (!worker.isReusable && _pool.remove(worker)) {
      await _retireWorker(worker);
      if (!_dynamicSpawning && _isActiveGeneration(generation) && !_quarantineFuseBlown) {
        await _restoreStaticPool(generation);
      }
    } else if (_dynamicSpawning && _queue.isEmpty && _pool.remove(worker)) {
      await _retireWorker(worker);
    }
    if (_isActiveGeneration(generation)) _schedule();
  }

  void _requestWorkerInitialization(int generation) {
    if (!_isActiveGeneration(generation) || !_dynamicSpawning || _queue.isEmpty || _quarantineFuseBlown) {
      return;
    }
    if (_workerInitialization != null || _activeRetirementCount > 0) return;
    if (_pool.isEmpty) _createWorkers(generation);
    final candidate = _pool.firstWhereOrNull(
      (worker) => worker.taskId == null && !worker.initialized && !worker.initializing,
    );
    if (candidate == null) return;

    late final Future<void> initialization;
    initialization = Future<void>.sync(candidate.initialize)
        .then((_) {
          if (!_isActiveGeneration(generation) || !_pool.contains(candidate)) return;
          _consecutiveInitializationFailures = 0;
          _schedule();
        })
        .onError((Object error, StackTrace stackTrace) async {
          if (!_isActiveGeneration(generation)) return;
          _pool.remove(candidate);
          await _retireWorker(candidate);
          _consecutiveInitializationFailures++;
          if (_consecutiveInitializationFailures >= _maximumInitializationFailures) {
            _failQueued(StateError('Worker initialization failed'), stackTrace);
            return;
          }
          if (_canCreateWorker) _pool.add(_workerFactory());
        })
        .whenComplete(() {
          if (identical(_workerInitialization, initialization)) {
            _workerInitialization = null;
          }
          if (_isActiveGeneration(generation) && _queue.isNotEmpty) _schedule();
        });
    _workerInitialization = initialization;
  }

  Future<void> _restoreStaticPool(int generation) async {
    if (_activeRetirementCount > 0) return;
    while (_isActiveGeneration(generation) &&
        !_quarantineFuseBlown &&
        _pool.length < _isolatesCount &&
        _canCreateWorker) {
      final replacement = _workerFactory();
      _pool.add(replacement);
      try {
        await replacement.initialize();
      } on Object catch (error, stackTrace) {
        _pool.remove(replacement);
        await _retireWorker(replacement);
        _failQueued(error, stackTrace);
        return;
      }
      if (!_isActiveGeneration(generation) || !_pool.contains(replacement)) return;
    }
  }

  void _cancel(Task task) {
    task.cancel();
    _queue.remove(task);
    final targetWorker = _pool.firstWhereOrNull((worker) => worker.taskId == task.id);
    if (task is Gentle) {
      targetWorker?.requestGentleCancellation();
    } else {
      if (targetWorker != null) {
        _pool.remove(targetWorker);
        unawaited(_retireCancelledWorker(targetWorker, _generation));
      }
    }
    _log.finer('Worker task cancelled');
    _schedule();
  }

  bool _isActiveGeneration(int generation) => _acceptingWork && generation == _generation;

  Future<void> _retireCancelledWorker(IsolateWorker worker, int generation) async {
    await _retireWorker(worker);
    if (!_dynamicSpawning && _isActiveGeneration(generation) && !_quarantineFuseBlown) {
      await _restoreStaticPool(generation);
    }
    if (_isActiveGeneration(generation)) _schedule();
  }

  Future<WorkerDisposal> _retireWorker(IsolateWorker worker) {
    _activeRetirementCount++;
    final retirementGeneration = _generation;
    late final Future<WorkerDisposal> retirement;
    retirement = _disposeWorker(worker).then((disposal) {
      _activeRetirementCount--;
      if (disposal == WorkerDisposal.quarantined) {
        _hasQuarantinedRetirement = true;
        _quarantinedRetirementCount++;
        _updateQuarantineFuse();
      }
      return disposal;
    });
    _retirements.add(retirement);
    unawaited(
      retirement.whenComplete(() {
        _retirements.remove(retirement);
        if (_isActiveGeneration(retirementGeneration)) _schedule();
      }),
    );
    return retirement;
  }

  Future<WorkerDisposal> _disposeWorker(IsolateWorker worker) async {
    try {
      return await worker.dispose();
    } on Object {
      return WorkerDisposal.quarantined;
    }
  }

  void _updateQuarantineFuse() {
    if (_quarantinedRetirementCount < _workerCapacity) return;
    _quarantineFuseBlown = true;
    _failQueued(StateError('Worker quarantine capacity exhausted'), StackTrace.current);
  }

  int get _workerCapacity => _configuredQuarantineCapacity ?? min(max(_isolatesCount * 2, 4), 16);

  int get _capacityInUse => _pool.length + _activeRetirementCount + _quarantinedRetirementCount;

  bool get _canCreateWorker => !_quarantineFuseBlown && _capacityInUse < _workerCapacity;

  void _failQueued(Object error, StackTrace stackTrace) {
    while (_queue.isNotEmpty) {
      _queue.removeFirst().complete(null, error, stackTrace);
    }
  }

  void _ensureAcceptingWork() {
    if (!_acceptingWork || _quarantineFuseBlown) {
      throw StateError('worker_manager is not accepting work');
    }
  }
}
