import 'dart:async';

final class ManualUploadPreparationGate {
  final Map<String, Future<void>> _pending = {};
  final Object _zoneKey = Object();

  bool holds(String key) {
    final scope = Zone.current[_zoneKey];
    return scope is _PreparationScope && scope.active && scope.key == key;
  }

  Future<T> run<T>(String key, Future<T> Function() action) async {
    if (holds(key)) return action();
    final previous = _pending[key];
    final released = Completer<void>();
    _pending[key] = released.future;
    final scope = _PreparationScope(key);
    try {
      await previous;
      return await runZoned(action, zoneValues: {_zoneKey: scope});
    } finally {
      scope.active = false;
      released.complete();
      if (identical(_pending[key], released.future)) unawaited(_pending.remove(key));
    }
  }
}

final class _PreparationScope {
  _PreparationScope(this.key);

  final String key;
  bool active = true;
}
