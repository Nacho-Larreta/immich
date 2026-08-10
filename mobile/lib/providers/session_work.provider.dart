import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('SessionWork');

final sessionWorkProvider = Provider<SessionWork>((ref) {
  final coordinator = ref.read(serverReachabilityCoordinatorProvider);
  final backgroundSync = ref.read(backgroundSyncProvider);
  return SessionWork(
    activateSession: coordinator.activateSession,
    syncLocal: ({required full}) => backgroundSync.syncLocal(full: full),
    cancelLocalSync: backgroundSync.cancelLocal,
  );
});

final class SessionWork {
  const SessionWork({
    required void Function({Uri? confirmedEndpoint}) activateSession,
    required Future<void> Function({required bool full}) syncLocal,
    required Future<void> Function() cancelLocalSync,
  }) : _activateSession = activateSession,
       _syncLocal = syncLocal,
       _cancelLocalSync = cancelLocalSync;

  final void Function({Uri? confirmedEndpoint}) _activateSession;
  final Future<void> Function({required bool full}) _syncLocal;
  final Future<void> Function() _cancelLocalSync;

  void activate({Uri? confirmedEndpoint, bool hasRemoteAuthentication = true, required bool fullLocalSync}) {
    if (hasRemoteAuthentication) {
      _activateSession(confirmedEndpoint: confirmedEndpoint);
    }
    triggerLocalSync(full: fullLocalSync);
  }

  void triggerLocalSync({required bool full}) {
    unawaited(
      _syncLocal(full: full).catchError((Object error, StackTrace stackTrace) {
        _log.warning('Local gallery sync failed', error, stackTrace);
      }),
    );
  }

  Future<void> cancelLocalSync() => _cancelLocalSync();
}
