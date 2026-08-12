final class BackupDisableBarrier {
  BackupDisableBarrier(Future<bool> Function() disable) : _disable = disable;

  final Future<bool> Function() _disable;
  Future<bool>? _operation;

  Future<bool> disable() async {
    final active = _operation;
    if (active != null) return active;
    final operation = _disable();
    _operation = operation;
    try {
      return await operation;
    } finally {
      if (identical(_operation, operation)) _operation = null;
    }
  }
}
