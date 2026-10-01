final class ManualUploadOwnerDrain {
  final Set<Future<void> Function()> _owners = {};

  Future<void> Function() register(Future<void> Function() stop) {
    Future<void>? stopping;
    late Future<void> Function() release;
    release = () => stopping ??= stop().whenComplete(() => _owners.remove(release));
    _owners.add(release);
    return release;
  }

  Future<void> drain() => Future.wait(_owners.toList().map((stop) => stop()));
}
