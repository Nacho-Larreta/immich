enum TemporaryFileOwnership { caller, external }

abstract class TemporaryFileLease {
  TemporaryFileLease({required this.path, required this.ownership}) {
    if (path.trim().isEmpty) {
      throw ArgumentError.value(path, 'path', 'Must not be empty');
    }
  }

  final String path;
  final TemporaryFileOwnership ownership;

  Future<void>? _releaseOperation;
  bool _isReleased = false;

  bool get isReleased => _isReleased;

  Future<void> release() => _releaseOperation ??= _releaseOnce();

  Future<void> _releaseOnce() async {
    await releaseResource();
    _isReleased = true;
  }

  Future<void> releaseResource();
}
