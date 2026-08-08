import 'dart:async';

final class SessionMutationMutex {
  Future<void> _tail = Future.value();

  Future<T> protect<T>(Future<T> Function() mutation) {
    final predecessor = _tail;
    final completion = Completer<void>();
    _tail = completion.future;

    return predecessor.then((_) => mutation()).whenComplete(completion.complete);
  }
}
