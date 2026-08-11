import 'dart:async';

Future<void> cancelRejectedTaskAndWait({
  required Future<void> Function() cancelAndWait,
  required Future<void> callbackSettlement,
}) async {
  final terminal = cancelAndWait();
  await Future.wait([terminal, callbackSettlement]);
}

final class StreamingTaskLifecycle {
  final Completer<void> _terminal = Completer<void>();
  var _cancelRequested = false;

  bool get cancelled => _cancelRequested;
  Future<void> get completed => _terminal.future;

  Future<void> cancelAndWait(void Function() cancelNative) {
    if (_terminal.isCompleted) return completed;
    if (!_cancelRequested) {
      _cancelRequested = true;
      cancelNative();
    }
    return completed;
  }

  void didComplete() {
    if (!_terminal.isCompleted) _terminal.complete();
  }
}

final class OwnedStreamingTasks<T> {
  OwnedStreamingTasks({required this.cancelAndWait, required this.completed});

  final Future<void> Function(T task) cancelAndWait;
  final Future<void> Function(T task) completed;
  final Set<T> _tasks = {};
  var _closed = false;
  Future<void>? _drain;

  int get activeCount => _tasks.length;
  bool get isDrained => _closed && _tasks.isEmpty;

  bool admit(T task) {
    if (_closed) return false;
    _tasks.add(task);
    unawaited(completed(task).whenComplete(() => _tasks.remove(task)));
    return true;
  }

  Future<void> closeAndDrain() {
    final existing = _drain;
    if (existing != null) return existing;
    _closed = true;
    final tasks = _tasks.toList(growable: false);
    return _drain = Future.wait(tasks.map(cancelAndWait));
  }
}
