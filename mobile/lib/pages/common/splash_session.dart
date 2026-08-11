enum SplashDestination { timeline }

final class SplashSessionBootstrap {
  SplashSessionBootstrap({
    required bool Function() hydrateCachedSession,
    required void Function(SplashDestination destination) navigate,
    void Function({required bool hasRemoteAuthentication})? triggerPostNavigationWork,
  }) : _hydrateCachedSession = hydrateCachedSession,
       _navigate = navigate,
       _triggerPostNavigationWork = triggerPostNavigationWork;

  final bool Function() _hydrateCachedSession;
  final void Function(SplashDestination destination) _navigate;
  final void Function({required bool hasRemoteAuthentication})? _triggerPostNavigationWork;
  bool _started = false;

  Future<void> run() async {
    if (_started) {
      return;
    }
    _started = true;
    final hasRemoteAuthentication = _hydrateCachedSession();
    _navigate(SplashDestination.timeline);
    _triggerPostNavigationWork?.call(hasRemoteAuthentication: hasRemoteAuthentication);
  }
}
