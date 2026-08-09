import 'dart:async';

enum SplashDestination { timeline, login }

final class SplashSessionBootstrap {
  const SplashSessionBootstrap({
    required bool Function() hydrateCachedSession,
    required Future<void> Function(SplashDestination destination) navigate,
    Future<void> Function()? triggerPostNavigationWork,
  }) : _hydrateCachedSession = hydrateCachedSession,
       _navigate = navigate,
       _triggerPostNavigationWork = triggerPostNavigationWork;

  final bool Function() _hydrateCachedSession;
  final Future<void> Function(SplashDestination destination) _navigate;
  final Future<void> Function()? _triggerPostNavigationWork;

  Future<void> run() async {
    final destination = _hydrateCachedSession() ? SplashDestination.timeline : SplashDestination.login;
    await _navigate(destination);

    if (destination == SplashDestination.timeline && _triggerPostNavigationWork != null) {
      unawaited(_triggerPostNavigationWork());
    }
  }
}
