import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/asset/asset_metadata.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/connectivity_monitor.interface.dart';
import 'package:immich_mobile/domain/models/backup_candidate_key.model.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/models/backup_run_binding.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/extensions/translate_extensions.dart';
import 'package:immich_mobile/infrastructure/repositories/backup.repository.dart';
import 'package:immich_mobile/infrastructure/repositories/storage.repository.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/backup/backup_execution.provider.dart';
import 'package:immich_mobile/providers/infrastructure/storage.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:logging/logging.dart';
import 'package:path/path.dart' as p;
import 'package:photo_manager/photo_manager.dart' show PMProgressHandler;

/// Callbacks for upload progress and status updates
class UploadCallbacks {
  final void Function(String id, String filename, int bytes, int totalBytes)? onProgress;
  final void Function(String localId, String remoteId)? onSuccess;
  final void Function(String id, String errorMessage)? onError;
  final void Function(String id, double progress)? onICloudProgress;

  const UploadCallbacks({this.onProgress, this.onSuccess, this.onError, this.onICloudProgress});
}

final foregroundUploadServiceProvider = Provider((ref) {
  return ForegroundUploadService(
    ref.watch(uploadRepositoryProvider),
    ref.watch(storageRepositoryProvider),
    ref.watch(backupRepositoryProvider),
    ref.watch(nativeConnectivityMonitorProvider) as ConnectivitySnapshotMonitorPort,
    ref.watch(appSettingsServiceProvider),
    ref.watch(assetMediaRepositoryProvider),
    candidateGate: ref.watch(backupExecutionLeaseProvider),
  );
});

/// Service for handling foreground HTTP uploads
///
/// This service handles synchronous uploads using HTTP client with
/// concurrent worker pools. Used for manual backups, auto backups
/// (foreground mode), and share intent uploads.
class ForegroundUploadService {
  ForegroundUploadService(
    this._uploadRepository,
    this._storageRepository,
    this._backupRepository,
    this._connectivity,
    this._appSettingsService,
    this._assetMediaRepository, {
    BackupExecutionLeasePort? candidateGate,
    String Function(LocalAsset asset)? candidateKeyForAsset,
  }) : _candidateGate = candidateGate,
       _candidateKeyForAsset =
           candidateKeyForAsset ??
           ((asset) => BackupCandidateKey.fromLocalIdentity(
             deviceId: Store.get(StoreKey.deviceId),
             localAssetId: asset.id,
           ).value);

  final UploadRepository _uploadRepository;
  final StorageRepository _storageRepository;
  final DriftBackupRepository _backupRepository;
  final ConnectivitySnapshotMonitorPort _connectivity;
  final AppSettingsService _appSettingsService;
  final AssetMediaRepository _assetMediaRepository;
  final BackupExecutionLeasePort? _candidateGate;
  final String Function(LocalAsset asset) _candidateKeyForAsset;
  final Logger _logger = Logger('ForegroundUploadService');

  bool shouldAbortUpload = false;

  Future<({int total, int remainder, int processing})> getBackupCounts(String userId) {
    return _backupRepository.getAllCounts(userId);
  }

  Future<List<LocalAsset>> getBackupCandidates(String userId, {bool onlyHashed = true}) {
    return _backupRepository.getCandidates(userId, onlyHashed: onlyHashed);
  }

  /// Bulk upload of backup candidates from selected albums
  Future<void> uploadCandidates(
    String userId,
    Completer<void> cancelToken, {
    UploadCallbacks callbacks = const UploadCallbacks(),
    bool useSequentialUpload = false,
    BackupRunBinding? binding,
    BackupExecutionLease? executionLease,
    bool Function(BackupRunBinding binding)? isBindingCurrent,
  }) async {
    bool current() => binding == null || isBindingCurrent?.call(binding) == true;
    Future<bool> gate() async {
      if (!current()) return false;
      if (binding == null) return true;
      final wifiCurrent = await _hasCurrentWifi(binding);
      return wifiCurrent && current();
    }

    if (!await gate()) return;
    final candidates = await _backupRepository.getCandidates(userId);
    if (!await gate()) return;
    if (candidates.isEmpty) {
      return;
    }

    final transportSnapshot = await _connectivity.readCurrentSnapshot();
    final hasWifi = transportSnapshot.hasWifi;
    _logger.info(hasWifi ? 'foreground_upload_transport_wifi' : 'foreground_upload_transport_non_wifi');
    if (binding != null && !hasWifi) return;

    if (useSequentialUpload) {
      await _uploadSequentially(
        items: candidates,
        cancelToken: cancelToken,
        hasWifi: hasWifi,
        callbacks: callbacks,
        binding: binding,
        executionLease: executionLease,
        isBindingCurrent: current,
      );
    } else {
      await _executeWithWorkerPool<LocalAsset>(
        items: candidates,
        cancelToken: cancelToken,
        shouldSkip: (asset) {
          final requireWifi = _shouldRequireWiFi(asset);
          return requireWifi && !hasWifi;
        },
        processItem: (asset) => _uploadSingleAsset(
          asset,
          cancelToken,
          callbacks: callbacks,
          binding: binding,
          executionLease: executionLease,
          isBindingCurrent: current,
        ),
      );
    }
  }

  /// Sequential upload - used for background isolate where concurrent HTTP clients may cause issues
  Future<void> _uploadSequentially({
    required List<LocalAsset> items,
    required Completer<void> cancelToken,
    required bool hasWifi,
    required UploadCallbacks callbacks,
    BackupRunBinding? binding,
    BackupExecutionLease? executionLease,
    required bool Function() isBindingCurrent,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    for (final asset in items) {
      if (shouldAbortUpload || cancelToken.isCompleted || !isBindingCurrent()) {
        break;
      }

      final requireWifi = _shouldRequireWiFi(asset);
      if (requireWifi && !hasWifi) {
        _logger.warning('foreground_upload_requires_wifi');
        continue;
      }

      await _uploadSingleAsset(
        asset,
        cancelToken,
        callbacks: callbacks,
        binding: binding,
        executionLease: executionLease,
        isBindingCurrent: isBindingCurrent,
      );
    }
  }

  /// Manually upload picked local assets
  Future<void> uploadManual(
    List<LocalAsset> localAssets, {
    Completer<void>? cancelToken,
    UploadCallbacks callbacks = const UploadCallbacks(),
  }) async {
    if (localAssets.isEmpty) {
      return;
    }

    await _executeWithWorkerPool<LocalAsset>(
      items: localAssets,
      cancelToken: cancelToken,
      processItem: (asset) => _uploadSingleAsset(asset, cancelToken, callbacks: callbacks),
    );
  }

  /// Upload files from shared intent
  Future<void> uploadShareIntent(
    List<File> files, {
    Completer<void>? cancelToken,
    void Function(String fileId, int bytes, int totalBytes)? onProgress,
    void Function(String fileId)? onSuccess,
    void Function(String fileId, String errorMessage)? onError,
  }) async {
    if (files.isEmpty) {
      return;
    }
    await _executeWithWorkerPool<File>(
      items: files,
      cancelToken: cancelToken,
      processItem: (file) async {
        final fileId = p.hash(file.path).toString();

        final result = await _uploadSingleFile(
          file,
          deviceAssetId: fileId,
          cancelToken: cancelToken,
          onProgress: (bytes, totalBytes) => onProgress?.call(fileId, bytes, totalBytes),
        );

        if (result.isSuccess) {
          onSuccess?.call(fileId);
        } else if (!result.isCancelled && result.errorMessage != null) {
          onError?.call(fileId, result.errorMessage!);
        }
      },
    );
  }

  void cancel() {
    shouldAbortUpload = true;
  }

  /// Generic worker pool for concurrent uploads
  ///
  /// [items] - List of items to process
  /// [cancelToken] - Token to cancel the operation
  /// [processItem] - Function to process each item with an HTTP client
  /// [shouldSkip] - Optional function to skip items (e.g., WiFi requirement check)
  /// [concurrentWorkers] - Number of concurrent workers (default: 3)
  Future<void> _executeWithWorkerPool<T>({
    required List<T> items,
    required Completer<void>? cancelToken,
    required Future<void> Function(T item) processItem,
    bool Function(T item)? shouldSkip,
    int concurrentWorkers = 3,
  }) async {
    await _storageRepository.clearCache();
    shouldAbortUpload = false;

    int currentIndex = 0;

    Future<void> worker() async {
      while (true) {
        if (shouldAbortUpload || (cancelToken != null && cancelToken.isCompleted)) {
          break;
        }

        final index = currentIndex;
        if (index >= items.length) {
          break;
        }
        currentIndex++;

        final item = items[index];

        if (shouldSkip?.call(item) ?? false) {
          continue;
        }

        await processItem(item);
      }
    }

    final workerFutures = <Future<void>>[];
    for (int i = 0; i < concurrentWorkers; i++) {
      workerFutures.add(worker());
    }

    await Future.wait(workerFutures);
  }

  Future<void> _uploadSingleAsset(
    LocalAsset asset,
    Completer<void>? cancelToken, {
    required UploadCallbacks callbacks,
    BackupRunBinding? binding,
    BackupExecutionLease? executionLease,
    bool Function()? isBindingCurrent,
  }) async {
    File? file;
    File? livePhotoFile;

    try {
      Future<bool> gate() async {
        if (isBindingCurrent?.call() == false) return false;
        if (binding == null) return true;
        final wifiCurrent = await _hasCurrentWifi(binding);
        return wifiCurrent && isBindingCurrent?.call() != false;
      }

      if (!await gate()) return;
      final candidateKey = binding == null ? null : _candidateKeyForAsset(asset);
      if (!await _autoCandidateAllowed(executionLease, candidateKey)) return;
      if (!await gate()) return;
      final entity = await _storageRepository.getAssetEntityForAsset(asset);
      if (!await gate()) return;
      if (entity == null) {
        callbacks.onError?.call(
          asset.localId!,
          CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
        );
        return;
      }

      if (!await gate()) return;
      final isAvailableLocally = await _storageRepository.isAssetAvailableLocally(asset.id);

      if (!isAvailableLocally && CurrentPlatform.isIOS) {
        _logger.info('foreground_upload_loading_cloud_asset');

        // Create progress handler for iCloud download
        PMProgressHandler? progressHandler;
        StreamSubscription? progressSubscription;

        progressHandler = PMProgressHandler();
        progressSubscription = progressHandler.stream.listen((event) {
          callbacks.onICloudProgress?.call(asset.localId!, event.progress);
        });

        try {
          if (!await gate()) return;
          file = await _storageRepository.loadFileFromCloud(asset.id, progressHandler: progressHandler);
          if (entity.isLivePhoto) {
            if (!await gate()) return;
            livePhotoFile = await _storageRepository.loadMotionFileFromCloud(
              asset.id,
              progressHandler: progressHandler,
            );
          }
        } finally {
          await progressSubscription.cancel();
        }
      } else {
        // Get files locally
        if (!await gate()) return;
        file = await _storageRepository.getFileForAsset(asset.id);
        if (file == null) {
          _logger.warning('foreground_upload_file_unavailable');
          callbacks.onError?.call(
            asset.localId!,
            CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
          );
          return;
        }

        // For live photos, get the motion video file
        if (entity.isLivePhoto) {
          if (!await gate()) return;
          livePhotoFile = await _storageRepository.getMotionFileForAsset(asset);
          if (livePhotoFile == null) {
            _logger.warning('foreground_upload_live_photo_part_unavailable');
            callbacks.onError?.call(
              asset.localId!,
              CurrentPlatform.isAndroid ? "asset_not_found_on_device_android".t() : "asset_not_found_on_device_ios".t(),
            );
          }
        }
      }

      if (file == null) {
        _logger.warning('foreground_upload_cloud_file_unavailable');
        callbacks.onError?.call(asset.localId!, "asset_not_found_on_icloud".t());
        return;
      }

      if (!await gate()) return;
      String fileName = await _assetMediaRepository.getOriginalFilename(asset.id) ?? asset.name;

      /// Handle special file name from DJI or Fusion app
      /// If the file name has no extension, likely due to special renaming template by specific apps
      /// we append the original extension from the asset name
      final hasExtension = p.extension(fileName).isNotEmpty;
      if (!hasExtension) {
        fileName = p.setExtension(fileName, p.extension(asset.name));
      }

      final originalFileName = entity.isLivePhoto ? p.setExtension(fileName, p.extension(file.path)) : fileName;
      final deviceId = Store.get(StoreKey.deviceId);

      final fields = {
        'deviceAssetId': asset.localId!,
        'deviceId': deviceId,
        'fileCreatedAt': asset.createdAt.toUtc().toIso8601String(),
        'fileModifiedAt': asset.updatedAt.toUtc().toIso8601String(),
        'isFavorite': asset.isFavorite.toString(),
        'duration': asset.duration.toString(),
      };

      // Upload live photo video first if available
      String? livePhotoVideoId;
      if (entity.isLivePhoto && livePhotoFile != null) {
        if (!await gate()) return;
        if (!await _autoCandidateAllowed(executionLease, candidateKey)) return;
        if (!await gate()) return;
        final livePhotoTitle = p.setExtension(originalFileName, p.extension(livePhotoFile.path));

        final onProgress = callbacks.onProgress;
        final livePhotoResult = await _uploadRepository.uploadFile(
          file: livePhotoFile,
          originalFileName: livePhotoTitle,
          fields: fields,
          cancelToken: cancelToken,
          onProgress: onProgress != null
              ? (bytes, totalBytes) => onProgress(asset.localId!, livePhotoTitle, bytes, totalBytes)
              : null,
          logContext: 'live_photo_video',
          apiEndpoint: binding?.apiEndpoint,
          isContextCurrent: isBindingCurrent,
        );

        if (livePhotoResult.isSuccess && livePhotoResult.remoteAssetId != null) {
          livePhotoVideoId = livePhotoResult.remoteAssetId;
        }
      }

      if (livePhotoVideoId != null) {
        fields['livePhotoVideoId'] = livePhotoVideoId;
      }

      // Add cloudId metadata only to the still image, not the motion video, becasue when the sync id happens, the motion video can get associated with the wrong still image.
      if (CurrentPlatform.isIOS && asset.cloudId != null) {
        fields['metadata'] = jsonEncode([
          RemoteAssetMetadataItem(
            key: RemoteAssetMetadataKey.mobileApp,
            value: RemoteAssetMobileAppMetadata(
              cloudId: asset.cloudId,
              createdAt: asset.createdAt.toIso8601String(),
              adjustmentTime: asset.adjustmentTime?.toIso8601String(),
              latitude: asset.latitude?.toString(),
              longitude: asset.longitude?.toString(),
            ),
          ),
        ]);
      }

      final onProgress = callbacks.onProgress;
      if (!await _autoCandidateAllowed(executionLease, candidateKey)) return;
      if (!await gate()) return;
      final result = await _uploadRepository.uploadFile(
        file: file,
        originalFileName: originalFileName,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress != null
            ? (bytes, totalBytes) => onProgress(asset.localId!, originalFileName, bytes, totalBytes)
            : null,
        logContext: 'asset_upload',
        apiEndpoint: binding?.apiEndpoint,
        isContextCurrent: isBindingCurrent,
      );

      if (result.isSuccess && result.remoteAssetId != null) {
        callbacks.onSuccess?.call(asset.localId!, result.remoteAssetId!);
      } else if (result.isCancelled || result.isStaleContext) {
        _logger.warning('foreground_upload_cancelled');
        shouldAbortUpload = true;
      } else if (result.errorMessage != null) {
        _logger.severe('foreground_upload_rejected');

        callbacks.onError?.call(asset.localId!, result.errorMessage!);

        if (result.errorMessage == "Quota has been exceeded!") {
          shouldAbortUpload = true;
        }
      }
    } on Object {
      _logger.severe('foreground_upload_asset_failed');
      callbacks.onError?.call(asset.localId!, 'Upload failed');
    } finally {
      if (Platform.isIOS) {
        try {
          await file?.delete();
          await livePhotoFile?.delete();
        } on Object {
          _logger.severe('foreground_upload_cleanup_failed');
        }
      }
    }
  }

  Future<bool> _hasCurrentWifi(BackupRunBinding binding) async {
    final snapshot = await _connectivity.readCurrentSnapshot();
    return snapshot.hasWifi &&
        snapshot.monitorEpoch == binding.transportEpoch &&
        snapshot.revision == binding.transportRevision;
  }

  Future<bool> _autoCandidateAllowed(BackupExecutionLease? lease, String? candidateKey) async {
    if (lease == null && candidateKey == null) return true;
    if (lease == null || candidateKey == null || _candidateGate == null) return false;
    return _candidateGate.allowForegroundCandidateUnlessQuarantined(
      runToken: lease.runToken,
      bindingDigest: lease.bindingDigest,
      candidateKey: candidateKey,
    );
  }

  Future<UploadResult> _uploadSingleFile(
    File file, {
    required String deviceAssetId,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
  }) async {
    try {
      final stats = await file.stat();
      final fileCreatedAt = stats.changed;
      final fileModifiedAt = stats.modified;
      final filename = p.basename(file.path);

      final fields = {
        'deviceAssetId': deviceAssetId,
        'deviceId': Store.get(StoreKey.deviceId),
        'fileCreatedAt': fileCreatedAt.toUtc().toIso8601String(),
        'fileModifiedAt': fileModifiedAt.toUtc().toIso8601String(),
        'isFavorite': 'false',
        'duration': '0',
      };

      return await _uploadRepository.uploadFile(
        file: file,
        originalFileName: filename,
        fields: fields,
        cancelToken: cancelToken,
        onProgress: onProgress,
        logContext: 'share_intent_upload',
      );
    } on Object {
      return UploadResult.error(errorMessage: 'Upload failed');
    }
  }

  bool _shouldRequireWiFi(LocalAsset asset) {
    bool requiresWiFi = true;

    if (asset.isVideo && _appSettingsService.getSetting(AppSettingsEnum.useCellularForUploadVideos)) {
      requiresWiFi = false;
    } else if (!asset.isVideo && _appSettingsService.getSetting(AppSettingsEnum.useCellularForUploadPhotos)) {
      requiresWiFi = false;
    }

    return requiresWiFi;
  }
}
