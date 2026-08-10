import 'dart:async';

enum SplashDestination { timeline }

final class SplashSessionBootstrap {
  const SplashSessionBootstrap({
    required bool Function() hydrateCachedSession,
    required Future<void> Function(SplashDestination destination) navigate,
    Future<void> Function({required bool hasRemoteAuthentication})? triggerPostNavigationWork,
  }) : _hydrateCachedSession = hydrateCachedSession,
       _navigate = navigate,
       _triggerPostNavigationWork = triggerPostNavigationWork;

  final bool Function() _hydrateCachedSession;
  final Future<void> Function(SplashDestination destination) _navigate;
  final Future<void> Function({required bool hasRemoteAuthentication})? _triggerPostNavigationWork;

  Future<void> run() async {
    final hasRemoteAuthentication = _hydrateCachedSession();
    await _navigate(SplashDestination.timeline);

    if (_triggerPostNavigationWork != null) {
      unawaited(_triggerPostNavigationWork(hasRemoteAuthentication: hasRemoteAuthentication));
    }
  }
}
