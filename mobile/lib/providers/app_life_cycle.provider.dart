import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup.provider.dart';
import 'package:immich_mobile/providers/gallery_permission.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/notification_permission.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/session_work.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:logging/logging.dart';

enum AppLifeCycleEnum { active, inactive, paused, resumed, detached, hidden }

class AppLifeCycleNotifier extends StateNotifier<AppLifeCycleEnum> {
  final Ref _ref;
  final LifecycleSessionWork _sessionWork;
  bool _wasPaused = false;

  // Add operation coordination
  Completer<void>? _resumeOperation;
  Completer<void>? _pauseOperation;

  final _log = Logger("AppLifeCycleNotifier");

  AppLifeCycleNotifier(this._ref, this._sessionWork) : super(AppLifeCycleEnum.active);

  AppLifeCycleEnum getAppState() {
    return state;
  }

  void handleAppResume() async {
    state = AppLifeCycleEnum.resumed;

    // Prevent overlapping resume operations
    if (_resumeOperation != null && !_resumeOperation!.isCompleted) {
      await _resumeOperation!.future;
      return;
    }

    if (_pauseOperation != null && !_pauseOperation!.isCompleted) {
      await _pauseOperation!.future;
    }

    _resumeOperation = Completer<void>();

    try {
      await _performResume();
    } catch (e, stackTrace) {
      _log.severe("Error during app resume", e, stackTrace);
    } finally {
      if (!_resumeOperation!.isCompleted) {
        _resumeOperation!.complete();
      }
      _resumeOperation = null;
    }
  }

  Future<void> _performResume() async {
    // no need to resume because app was never really paused
    if (!_wasPaused) return;
    _wasPaused = false;

    await _sessionWork.resume(fullLocalSync: CurrentPlatform.isAndroid);

    await _ref.read(notificationPermissionProvider.notifier).getNotificationPermission();

    await _ref.read(galleryPermissionNotifier.notifier).getGalleryPermissionStatus();
  }

  void handleAppInactivity() {
    state = AppLifeCycleEnum.inactive;
    // do not stop/clean up anything on inactivity: issued on every orientation change
  }

  Future<void> handleAppPause() async {
    state = AppLifeCycleEnum.paused;
    _wasPaused = true;

    // Prevent overlapping pause operations
    if (_pauseOperation != null && !_pauseOperation!.isCompleted) {
      await _pauseOperation!.future;
      return;
    }

    if (_resumeOperation != null && !_resumeOperation!.isCompleted) {
      await _resumeOperation!.future;
    }

    _pauseOperation = Completer<void>();

    try {
      await _sessionWork.pause();
      await _performPause();
    } catch (e, stackTrace) {
      _log.severe("Error during app pause", e, stackTrace);
    } finally {
      if (!_pauseOperation!.isCompleted) {
        _pauseOperation!.complete();
      }
      _pauseOperation = null;
    }
  }

  Future<void> _performPause() => LogService.I.flush().catchError((_) {});

  Future<void> handleAppDetached() async {
    state = AppLifeCycleEnum.detached;

    unawaited(_ref.read(backgroundWorkerLockServiceProvider).unlock());

    // Flush logs before closing database
    try {
      await LogService.I.flush();
    } catch (_) {}
  }

  void handleAppHidden() {
    state = AppLifeCycleEnum.hidden;
    // do not stop/clean up anything on inactivity: issued on every orientation change
  }
}

final appStateProvider = StateNotifierProvider<AppLifeCycleNotifier, AppLifeCycleEnum>((ref) {
  final coordinator = ref.read(serverReachabilityCoordinatorProvider);
  final eagerBackup = ref.read(eagerBackupCoordinatorProvider);
  final backgroundSync = ref.read(backgroundSyncProvider);
  return AppLifeCycleNotifier(
    ref,
    LifecycleSessionWork(
      pauseReachability: coordinator.pause,
      resumeReachability: coordinator.resume,
      triggerLocalSync: ({required full}) => ref.read(sessionWorkProvider).triggerLocalSync(full: full),
      cancelLocalSync: ref.read(sessionWorkProvider).cancelLocalSync,
      cancelBackgroundSync: backgroundSync.cancel,
      stopBackup: ref.read(driftBackupProvider.notifier).stopForegroundBackup,
      pauseEagerBackup: () async {
        if (!await eagerBackup.suspendForeground()) return;
        final enabled = ref.read(appSettingsServiceProvider).getSetting(AppSettingsEnum.enableBackup);
        final user = ref.read(currentUserProvider);
        if (enabled && user != null) {
          await ref.read(driftBackupProvider.notifier).startBackupWithURLSession(user.id);
        }
      },
      resumeEagerBackup: () => eagerBackup.setForeground(true),
      disconnectWebsocket: ref.read(websocketProvider.notifier).disconnect,
      lockBackgroundWorker: ref.read(backgroundWorkerLockServiceProvider).lock,
      unlockBackgroundWorker: ref.read(backgroundWorkerLockServiceProvider).unlock,
    ),
  );
});

final class LifecycleSessionWork {
  const LifecycleSessionWork({
    required Future<void> Function() pauseReachability,
    required void Function() resumeReachability,
    required void Function({required bool full}) triggerLocalSync,
    required Future<void> Function() cancelLocalSync,
    required Future<void> Function() cancelBackgroundSync,
    required void Function() stopBackup,
    required Future<void> Function() pauseEagerBackup,
    required void Function() resumeEagerBackup,
    required void Function() disconnectWebsocket,
    required Future<void> Function() lockBackgroundWorker,
    required Future<void> Function() unlockBackgroundWorker,
  }) : _pauseReachability = pauseReachability,
       _resumeReachability = resumeReachability,
       _triggerLocalSync = triggerLocalSync,
       _cancelLocalSync = cancelLocalSync,
       _cancelBackgroundSync = cancelBackgroundSync,
       _stopBackup = stopBackup,
       _pauseEagerBackup = pauseEagerBackup,
       _resumeEagerBackup = resumeEagerBackup,
       _disconnectWebsocket = disconnectWebsocket,
       _lockBackgroundWorker = lockBackgroundWorker,
       _unlockBackgroundWorker = unlockBackgroundWorker;

  final Future<void> Function() _pauseReachability;
  final void Function() _resumeReachability;
  final void Function({required bool full}) _triggerLocalSync;
  final Future<void> Function() _cancelLocalSync;
  final Future<void> Function() _cancelBackgroundSync;
  final void Function() _stopBackup;
  final Future<void> Function() _pauseEagerBackup;
  final void Function() _resumeEagerBackup;
  final void Function() _disconnectWebsocket;
  final Future<void> Function() _lockBackgroundWorker;
  final Future<void> Function() _unlockBackgroundWorker;

  Future<void> pause() async {
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() operation) async {
      try {
        await operation();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(_pauseEagerBackup);
    await Future.wait([
      attempt(_pauseReachability),
      attempt(_cancelLocalSync),
      attempt(_stopBackup),
      attempt(_disconnectWebsocket),
      attempt(_cancelBackgroundSync),
    ]);
    await attempt(_unlockBackgroundWorker);
    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  Future<void> resume({required bool fullLocalSync}) async {
    await _lockBackgroundWorker();
    _resumeReachability();
    _resumeEagerBackup();
    _triggerLocalSync(full: fullLocalSync);
  }
}
