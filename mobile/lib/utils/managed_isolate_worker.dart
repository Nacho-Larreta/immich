import 'dart:async';
import 'dart:isolate';

import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:worker_manager/worker_manager.dart';

enum WorkerDisposal { terminated, quarantined }

enum WorkerTerminationSafety { safe, unsafe }

final class ManagedIsolateWorker {
  Isolate? _isolate;
  RawReceivePort? _receivePort;
  SendPort? _sendPort;
  Completer<void>? _ready;
  Future<void>? _initialization;
  Completer<Object?>? _result;
  Completer<WorkerTerminationSafety>? _activeTerminal;
  final Completer<void> _terminated = Completer<void>();
  void Function(Object value)? _onMessage;
  String? _taskId;
  var _acceptingWork = true;
  var _quarantined = false;
  var _terminationSafety = WorkerTerminationSafety.safe;

  bool get initialized => _ready?.isCompleted ?? false;
  bool get initializing => _initialization != null && !initialized;
  bool get isTerminated => _terminated.isCompleted;
  bool get isReusable =>
      initialized &&
      _acceptingWork &&
      !_quarantined &&
      _terminationSafety == WorkerTerminationSafety.safe &&
      _taskId == null;
  String? get taskId => _taskId;
  Future<void> get terminated => _terminated.future;

  Future<void> initialize() {
    if (isTerminated || _quarantined) {
      throw StateError('A disposed isolate worker cannot be initialized again');
    }
    if (initialized) return Future.value();
    return _initialization ??= _initialize();
  }

  Future<void> _initialize() async {
    final ready = _ready = Completer<void>();
    final receivePort = _receivePort = RawReceivePort();
    receivePort.handler = _handleMessage;
    final isolate = await Isolate.spawn(_runWorker, receivePort.sendPort, errorsAreFatal: false, paused: false);
    if (isTerminated) {
      isolate.kill(priority: Isolate.immediate);
      return;
    }
    _isolate = isolate;
    await Future.any([ready.future, terminated]);
  }

  Future<R> work<R>(Task<R> task) async {
    if (!isReusable) {
      throw StateError('Worker is not available for new work');
    }
    _taskId = task.id;
    _result = Completer<Object?>();
    _activeTerminal = Completer<WorkerTerminationSafety>();
    if (task is WithPort) {
      _onMessage = (task as WithPort).onMessage;
    }
    _sendPort!.send(task.execution);
    return await _result!.future as R;
  }

  void requestGentleCancellation() {
    if (_taskId != null && !isTerminated) {
      _sendPort?.send(const _GentleCancelRequest());
    }
  }

  Future<WorkerDisposal> dispose({Duration drainTimeout = const Duration(seconds: 5)}) async {
    if (isTerminated) return WorkerDisposal.terminated;
    _acceptingWork = false;
    final terminal = _activeTerminal;
    if (terminal == null) {
      if (_terminationSafety == WorkerTerminationSafety.unsafe) {
        _quarantined = true;
        return WorkerDisposal.quarantined;
      }
      _terminate();
      return WorkerDisposal.terminated;
    }

    requestGentleCancellation();
    try {
      final safety = await terminal.future.timeout(drainTimeout);
      if (safety == WorkerTerminationSafety.unsafe) {
        _quarantined = true;
        return WorkerDisposal.quarantined;
      }
    } on TimeoutException {
      _quarantined = true;
      unawaited(
        terminal.future.then((safety) {
          if (safety == WorkerTerminationSafety.safe) _terminate();
        }),
      );
      return WorkerDisposal.quarantined;
    }
    _terminate();
    return WorkerDisposal.terminated;
  }

  void _handleMessage(Object? message) {
    switch (message) {
      case SendPort port:
        _sendPort = port;
        _ready!.complete();
      case _WorkerSuccess(:final value):
        _result?.complete(value);
        _finishWork(WorkerTerminationSafety.safe);
      case _WorkerFailure(:final error, :final stackTrace, :final safeToTerminate):
        _result?.completeError(error, stackTrace);
        _finishWork(safeToTerminate ? WorkerTerminationSafety.safe : WorkerTerminationSafety.unsafe);
      case final Object value:
        _onMessage?.call(value);
      case null:
        break;
    }
  }

  void _finishWork(WorkerTerminationSafety safety) {
    _onMessage = null;
    _taskId = null;
    _result = null;
    _terminationSafety = safety;
    final terminal = _activeTerminal;
    _activeTerminal = null;
    if (terminal != null && !terminal.isCompleted) terminal.complete(safety);
  }

  void _terminate() {
    if (isTerminated) return;
    _acceptingWork = false;
    _receivePort?.close();
    _receivePort = null;
    _sendPort = null;
    _ready = null;
    _isolate?.kill(priority: Isolate.immediate);
    _isolate = null;
    _terminated.complete();
  }
}

void _runWorker(SendPort sendPort) {
  final receivePort = RawReceivePort();
  sendPort.send(receivePort.sendPort);
  _CancellationState? activeCancellation;

  receivePort.handler = (Object? message) async {
    if (message is _GentleCancelRequest) {
      activeCancellation?.cancel();
      return;
    }

    final cancellation = _CancellationState();
    activeCancellation = cancellation;
    try {
      final Object? result;
      if (message is Execute) {
        result = await message();
      } else if (message is ExecuteWithPort) {
        result = await message(sendPort);
      } else if (message is ExecuteGentle) {
        result = await message(cancellation.isCancelled);
      } else if (message is ExecuteGentleWithPort) {
        result = await message(sendPort, cancellation.isCancelled);
      } else {
        throw ArgumentError.value(message, 'message', 'Unsupported worker request');
      }
      sendPort.send(
        cancellation.isCancelled()
            ? _WorkerFailure(CanceledError(), StackTrace.current, safeToTerminate: true)
            : _WorkerSuccess(result),
      );
    } on Object catch (error, stackTrace) {
      final unsafe = isUnsafeWorkerTermination(error);
      sendPort.send(_WorkerFailure(error, unsafe ? StackTrace.empty : stackTrace, safeToTerminate: !unsafe));
    } finally {
      if (identical(activeCancellation, cancellation)) activeCancellation = null;
    }
  };
}

final class _CancellationState {
  var _cancelled = false;

  bool isCancelled() => _cancelled;
  void cancel() => _cancelled = true;
}

final class _GentleCancelRequest {
  const _GentleCancelRequest();
}

final class _WorkerSuccess {
  const _WorkerSuccess(this.value);

  final Object? value;
}

final class _WorkerFailure {
  const _WorkerFailure(this.error, this.stackTrace, {required this.safeToTerminate});

  final Object error;
  final StackTrace stackTrace;
  final bool safeToTerminate;
}
