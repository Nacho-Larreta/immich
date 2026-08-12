import 'dart:async';
import 'dart:io';
import 'dart:ui';

import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/services/log.service.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/logger_db.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart' show nativeSyncApiProvider;
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/auth.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/localization.service.dart';
import 'package:immich_mobile/utils/bootstrap.dart';
import 'package:immich_mobile/utils/debug_print.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';
import 'package:immich_mobile/wm_executor.dart';
import 'package:logging/logging.dart';

@visibleForTesting
Future<void> disposeWorkersBeforeOrdinaryCleanup({
  required Future<void> Function() disposeWorkers,
  required Future<void> Function() cleanupOrdinaryResources,
}) async {
  await disposeWorkers();
  await cleanupOrdinaryResources();
}

class BackgroundWorkerFgService {
  final BackgroundWorkerFgHostApi _foregroundHostApi;

  const BackgroundWorkerFgService(this._foregroundHostApi);

  // TODO: Move this call to native side once old timeline is removed
  Future<void> enable() => _foregroundHostApi.enable();

  Future<void> saveNotificationMessage(String title, String body) =>
      _foregroundHostApi.saveNotificationMessage(title, body);

  Future<void> configure({int? minimumDelaySeconds, bool? requireCharging}) => _foregroundHostApi.configure(
    BackgroundWorkerSettings(
      minimumDelaySeconds:
          minimumDelaySeconds ??
          Store.get(AppSettingsEnum.backupTriggerDelay.storeKey, AppSettingsEnum.backupTriggerDelay.defaultValue),
      requiresCharging:
          requireCharging ??
          Store.get(AppSettingsEnum.backupRequireCharging.storeKey, AppSettingsEnum.backupRequireCharging.defaultValue),
    ),
  );

  Future<void> disable() => _foregroundHostApi.disable();
}

class BackgroundWorkerBgService extends BackgroundWorkerFlutterApi {
  ProviderContainer? _ref;
  final Drift _drift;
  final DriftLogger _driftLogger;
  final BackgroundWorkerBgHostApi _backgroundHostApi;
  final _cancellationToken = Completer<void>();
  final Logger _logger = Logger('BackgroundWorkerBgService');

  bool _isCleanedUp = false;
  Future<void>? _cleanupFuture;

  BackgroundWorkerBgService({required Drift drift, required DriftLogger driftLogger})
    : _drift = drift,
      _driftLogger = driftLogger,
      _backgroundHostApi = BackgroundWorkerBgHostApi() {
    _ref = ProviderContainer(overrides: [driftProvider.overrideWith(driftOverride(drift))]);
    BackgroundWorkerFlutterApi.setUp(this);
  }

  bool get _isBackupEnabled => _ref?.read(appSettingsServiceProvider).getSetting(AppSettingsEnum.enableBackup) ?? false;

  Future<void> init() async {
    try {
      await Future.wait(
        [
          loadTranslations(),
          workerManagerPatch.init(dynamicSpawning: true),
          _ref?.read(authServiceProvider).setOpenApiServiceEndpoint(),
          // Initialize the file downloader
          FileDownloader().configure(
            globalConfig: [
              // maxConcurrent: 6, maxConcurrentByHost(server):6, maxConcurrentByGroup: 3
              (Config.holdingQueue, (6, 6, 3)),
              // On Android, if files are larger than 256MB, run in foreground service
              (Config.runInForegroundIfFileLargerThan, 256),
            ],
          ),
          FileDownloader().trackTasksInGroup(kDownloadGroupLivePhoto, markDownloadedComplete: false),
        ].nonNulls,
      );

      configureFileDownloaderNotifications();

      // Notify the host that the background worker service has been initialized and is ready to use
      unawaited(_backgroundHostApi.onInitialized());
    } on Object {
      _logger.severe('background_worker_initialization_failed');
      try {
        await _cleanup();
        unawaited(_backgroundHostApi.close());
      } on PlatformException catch (cleanupError) {
        if (cleanupError.code != unsafeWorkerTerminationCode) rethrow;
        unawaited(_backgroundHostApi.close());
      }
    }
  }

  @override
  Future<void> onAndroidUpload() async {
    _logger.info('Android background processing started');
    final sw = Stopwatch()..start();
    try {
      if (!await _syncAssets(hashTimeout: Duration(minutes: _isBackupEnabled ? 3 : 6))) {
        _logger.warning("Remote sync did not complete successfully, skipping backup");
        return;
      }
      await _handleBackup();
    } on Object {
      _logger.severe('background_worker_android_processing_failed');
    } finally {
      sw.stop();
      _logger.info('background_worker_android_processing_completed');
      await _cleanup();
    }
  }

  @override
  Future<void> onIosUpload(bool isRefresh, int? maxSeconds) async {
    _logger.info('iOS background upload started with maxSeconds: ${maxSeconds}s');
    final sw = Stopwatch()..start();
    try {
      final timeout = isRefresh ? const Duration(seconds: 5) : Duration(minutes: _isBackupEnabled ? 3 : 6);
      if (!await _syncAssets(hashTimeout: timeout)) {
        _logger.warning("Remote sync did not complete successfully, skipping backup");
        return;
      }

      final backupFuture = _handleBackup();
      if (maxSeconds != null) {
        await backupFuture.timeout(Duration(seconds: maxSeconds - 1), onTimeout: () {});
      } else {
        await backupFuture;
      }
    } on Object {
      _logger.severe('background_worker_ios_upload_failed');
    } finally {
      sw.stop();
      _logger.info('background_worker_ios_upload_completed');
      await _cleanup();
    }
  }

  @override
  Future<void> cancel() async {
    _logger.warning("Background worker cancelled");
    await _cleanup();
  }

  Future<void> _cleanup() => _cleanupFuture ??= _handleCleanup();

  Future<void> _handleCleanup() async {
    if (_isCleanedUp || _ref == null) {
      return;
    }

    await drainNetworkBeforeRelease(
      drainNetwork: NetworkRepository.drainAttachedWorker,
      logCode: (code) => dPrint(() => code),
      releaseResources: _releaseResources,
    );
  }

  Future<void> _releaseResources() async {
    try {
      _isCleanedUp = true;
      final backgroundSyncManager = _ref?.read(backgroundSyncProvider);
      final nativeSyncApi = _ref?.read(nativeSyncApiProvider);
      _logger.info("Cleaning up background worker");

      await disposeWorkersBeforeOrdinaryCleanup(
        disposeWorkers: workerManagerPatch.dispose,
        cleanupOrdinaryResources: () async {
          await _drift.close();
          await _driftLogger.close();

          _ref?.dispose();
          _ref = null;

          _cancellationToken.complete();
          final cleanupFutures = <Future<void>?>[
            nativeSyncApi?.cancelHashing(),
            LogService.I.dispose(),
            Store.dispose(),
            backgroundSyncManager?.cancel(),
          ];

          await Future.wait(cleanupFutures.nonNulls);
        },
      );
      _logger.info("Background worker resources cleaned up");
    } on PlatformException catch (error) {
      if (isUnsafeWorkerTermination(error)) rethrow;
      dPrint(() => resourceReleaseFailureLogCode);
      throw PlatformException(code: resourceReleaseFailureCode, message: resourceReleaseFailureLogCode);
    } on Object {
      dPrint(() => resourceReleaseFailureLogCode);
      throw PlatformException(code: resourceReleaseFailureCode, message: resourceReleaseFailureLogCode);
    }
  }

  Future<void> _handleBackup() async {
    await runZonedGuarded(() async {
      if (_isCleanedUp) {
        return;
      }

      if (!_isBackupEnabled) {
        _logger.info("Backup is disabled. Skipping backup routine");
        return;
      }

      final connectivity = _ref!.read(nativeConnectivityMonitorProvider) as ConnectivitySnapshotMonitorPort;
      await connectivity.initialSnapshot;
      final transport = await connectivity.readCurrentSnapshot();
      publishBackupTransportCursor(
        current: _ref!.read(backupTransportCursorProvider),
        snapshot: transport,
        publish: (cursor) => _ref!.read(backupTransportCursorProvider.notifier).state = cursor,
      );
      if (!transport.hasWifi) {
        _logger.info('background_backup_transport_unavailable');
        return;
      }

      final currentUser = _ref?.read(currentUserProvider);
      if (currentUser == null) {
        _logger.warning("No current user found. Skipping backup from background");
        return;
      }

      final binding = _ref?.read(backupRunBindingSourceProvider).capture();
      if (binding == null || binding.userId != currentUser.id) {
        _logger.info('background_backup_binding_unavailable');
        return;
      }

      if (Platform.isIOS) {
        return _ref?.read(driftBackupProvider.notifier).startBackupWithURLSession(currentUser.id);
      }

      await _ref
          ?.read(foregroundUploadServiceProvider)
          .uploadCandidates(
            currentUser.id,
            _cancellationToken,
            useSequentialUpload: true,
            binding: binding,
            isBindingCurrent: _ref!.read(backupRunBindingSourceProvider).isCurrent,
          );
    }, (_, _) => dPrint(() => 'background_worker_backup_zone_failed'));
  }

  Future<bool> _syncAssets({Duration? hashTimeout}) async {
    await _ref?.read(backgroundSyncProvider).syncLocal();
    if (_isCleanedUp) {
      return false;
    }

    final isSuccess = await _ref?.read(backgroundSyncProvider).syncRemote() ?? false;
    if (_isCleanedUp) {
      return isSuccess;
    }

    var hashFuture = _ref?.read(backgroundSyncProvider).hashAssets();
    if (hashTimeout != null && hashFuture != null) {
      hashFuture = hashFuture.timeout(
        hashTimeout,
        onTimeout: () {
          // Consume cancellation errors as we want to continue processing
        },
      );
    }

    await hashFuture;
    return isSuccess;
  }
}

class BackgroundWorkerLockService {
  final BackgroundWorkerLockApi _hostApi;
  const BackgroundWorkerLockService(this._hostApi);

  Future<void> lock() async {
    if (CurrentPlatform.isAndroid) {
      return _hostApi.lock();
    }
  }

  Future<void> unlock() async {
    if (CurrentPlatform.isAndroid) {
      return _hostApi.unlock();
    }
  }
}

/// Native entry invoked from the background worker. If renaming or moving this to a different
/// library, make sure to update the entry points and URI in native workers as well
@pragma('vm:entry-point')
Future<void> backgroundSyncNativeEntrypoint() async {
  WidgetsFlutterBinding.ensureInitialized();
  DartPluginRegistrant.ensureInitialized();

  final (drift, logDB) = await Bootstrap.initDomain(
    shouldBufferLogs: false,
    listenStoreUpdates: false,
    networkContextRole: NetworkContextRole.attachedWorker,
  );
  await BackgroundWorkerBgService(drift: drift, driftLogger: logDB).init();
}
