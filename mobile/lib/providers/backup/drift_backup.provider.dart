import 'dart:async';

import 'package:collection/collection.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:logging/logging.dart';

import 'package:immich_mobile/domain/models/album/local_album.model.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/backup_sync.model.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/providers/backup/backup_execution.provider.dart';
import 'package:immich_mobile/providers/backup/backup_enablement.provider.dart';
import 'package:immich_mobile/providers/backup/backup_sync_error.provider.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';

export 'package:immich_mobile/domain/models/backup_sync.model.dart' show BackupError;

class EnqueueStatus {
  final int enqueueCount;
  final int totalCount;

  const EnqueueStatus({required this.enqueueCount, required this.totalCount});

  EnqueueStatus copyWith({int? enqueueCount, int? totalCount}) {
    return EnqueueStatus(enqueueCount: enqueueCount ?? this.enqueueCount, totalCount: totalCount ?? this.totalCount);
  }

  @override
  String toString() => 'EnqueueStatus(enqueueCount: $enqueueCount, totalCount: $totalCount)';
}

class DriftUploadStatus {
  final String taskId;
  final String filename;
  final double progress;
  final int fileSize;
  final String networkSpeedAsString;
  final bool? isFailed;
  final String? error;

  const DriftUploadStatus({
    required this.taskId,
    required this.filename,
    required this.progress,
    required this.fileSize,
    required this.networkSpeedAsString,
    this.isFailed,
    this.error,
  });

  DriftUploadStatus copyWith({
    String? taskId,
    String? filename,
    double? progress,
    int? fileSize,
    String? networkSpeedAsString,
    bool? isFailed,
    String? error,
  }) {
    return DriftUploadStatus(
      taskId: taskId ?? this.taskId,
      filename: filename ?? this.filename,
      progress: progress ?? this.progress,
      fileSize: fileSize ?? this.fileSize,
      networkSpeedAsString: networkSpeedAsString ?? this.networkSpeedAsString,
      isFailed: isFailed ?? this.isFailed,
      error: error ?? this.error,
    );
  }

  @override
  String toString() {
    return 'DriftUploadStatus(progress: $progress, fileSize: $fileSize, isFailed: $isFailed)';
  }

  @override
  bool operator ==(covariant DriftUploadStatus other) {
    if (identical(this, other)) return true;

    return other.taskId == taskId &&
        other.filename == filename &&
        other.progress == progress &&
        other.fileSize == fileSize &&
        other.networkSpeedAsString == networkSpeedAsString &&
        other.isFailed == isFailed &&
        other.error == error;
  }

  @override
  int get hashCode {
    return taskId.hashCode ^
        filename.hashCode ^
        progress.hashCode ^
        fileSize.hashCode ^
        networkSpeedAsString.hashCode ^
        isFailed.hashCode ^
        error.hashCode;
  }
}

class DriftBackupState {
  final int totalCount;
  final int backupCount;
  final int remainderCount;
  final int processingCount;

  final bool isSyncing;
  final BackupError error;

  final Map<String, DriftUploadStatus> uploadItems;

  final Map<String, double> iCloudDownloadProgress;
  final EagerBackgroundUploadSnapshot? backgroundUploadSnapshot;

  const DriftBackupState({
    required this.totalCount,
    required this.backupCount,
    required this.remainderCount,
    required this.processingCount,
    required this.isSyncing,
    this.error = BackupError.none,
    required this.uploadItems,
    this.iCloudDownloadProgress = const {},
    this.backgroundUploadSnapshot,
  });

  DriftBackupState copyWith({
    int? totalCount,
    int? backupCount,
    int? remainderCount,
    int? processingCount,
    bool? isSyncing,
    BackupError? error,
    Map<String, DriftUploadStatus>? uploadItems,
    Map<String, double>? iCloudDownloadProgress,
    EagerBackgroundUploadSnapshot? backgroundUploadSnapshot,
    bool clearBackgroundUploadSnapshot = false,
  }) {
    return DriftBackupState(
      totalCount: totalCount ?? this.totalCount,
      backupCount: backupCount ?? this.backupCount,
      remainderCount: remainderCount ?? this.remainderCount,
      processingCount: processingCount ?? this.processingCount,
      isSyncing: isSyncing ?? this.isSyncing,
      error: error ?? this.error,
      uploadItems: uploadItems ?? this.uploadItems,
      iCloudDownloadProgress: iCloudDownloadProgress ?? this.iCloudDownloadProgress,
      backgroundUploadSnapshot: clearBackgroundUploadSnapshot
          ? null
          : backgroundUploadSnapshot ?? this.backgroundUploadSnapshot,
    );
  }

  int get errorCount => uploadItems.values.where((item) => item.isFailed == true).length;

  @override
  String toString() {
    return 'DriftBackupState(totalCount: $totalCount, backupCount: $backupCount, remainderCount: $remainderCount, processingCount: $processingCount, isSyncing: $isSyncing, error: $error, uploadItemCount: ${uploadItems.length})';
  }

  @override
  bool operator ==(covariant DriftBackupState other) {
    if (identical(this, other)) return true;
    final mapEquals = const DeepCollectionEquality().equals;

    return other.totalCount == totalCount &&
        other.backupCount == backupCount &&
        other.remainderCount == remainderCount &&
        other.processingCount == processingCount &&
        other.isSyncing == isSyncing &&
        other.error == error &&
        mapEquals(other.iCloudDownloadProgress, iCloudDownloadProgress) &&
        mapEquals(other.uploadItems, uploadItems) &&
        other.backgroundUploadSnapshot == backgroundUploadSnapshot;
  }

  @override
  int get hashCode {
    return totalCount.hashCode ^
        backupCount.hashCode ^
        remainderCount.hashCode ^
        processingCount.hashCode ^
        isSyncing.hashCode ^
        error.hashCode ^
        uploadItems.hashCode ^
        iCloudDownloadProgress.hashCode ^
        backgroundUploadSnapshot.hashCode;
  }
}

final StateNotifierProvider<DriftBackupNotifier, DriftBackupState> driftBackupProvider =
    StateNotifierProvider<DriftBackupNotifier, DriftBackupState>((ref) {
      final notifier = DriftBackupNotifier(
        ref.watch(foregroundUploadServiceProvider),
        ref.watch(backgroundUploadServiceProvider),
        UploadSpeedManager(),
        ref.watch(backupExecutionArbiterProvider),
        ref.watch(backupRunBindingSourceProvider),
        ref.watch(backupEnablementAuthorityProvider),
      );
      ref.listen(backupSyncErrorProvider, (_, next) => notifier.updateError(next));
      return notifier;
    });

class DriftBackupNotifier extends StateNotifier<DriftBackupState> implements EagerBackupActivityProjectionPort {
  DriftBackupNotifier(
    this._foregroundUploadService,
    this._backgroundUploadService,
    this._uploadSpeedManager,
    this._arbiter,
    this._bindings,
    this._enablementAuthority, {
    Duration backgroundOwnerTimeout = const Duration(seconds: 30),
  }) : _backgroundOwnerTimeout = backgroundOwnerTimeout,
       super(
         const DriftBackupState(
           totalCount: 0,
           backupCount: 0,
           remainderCount: 0,
           processingCount: 0,
           isSyncing: false,
           uploadItems: {},
           error: BackupError.none,
         ),
       );

  final ForegroundUploadService _foregroundUploadService;
  final BackgroundUploadService _backgroundUploadService;
  final UploadSpeedManager _uploadSpeedManager;
  final BackgroundBackupAdmissionPort _arbiter;
  final BackupRunBindingSourcePort _bindings;
  final BackupEnablementAuthorityPort _enablementAuthority;
  final Duration _backgroundOwnerTimeout;
  Completer<void>? _cancelToken;

  final _logger = Logger("DriftBackupNotifier");

  /// Remove upload item from state
  void _removeUploadItem(String taskId) {
    if (!mounted) {
      _logger.warning("Skip _removeUploadItem: notifier disposed");
      return;
    }
    if (state.uploadItems.containsKey(taskId)) {
      final updatedItems = Map<String, DriftUploadStatus>.from(state.uploadItems);
      updatedItems.remove(taskId);
      state = state.copyWith(uploadItems: updatedItems);
    }
  }

  Future<void> getBackupStatus(String userId) async {
    if (!mounted) {
      _logger.warning("Skip getBackupStatus (pre-call): notifier disposed");
      return;
    }
    final counts = await _foregroundUploadService.getBackupCounts(userId);
    if (!mounted) {
      _logger.warning("Skip getBackupStatus (post-call): notifier disposed");
      return;
    }

    state = state.copyWith(
      totalCount: counts.total,
      backupCount: counts.total - counts.remainder,
      remainderCount: counts.remainder,
      processingCount: counts.processing,
    );
  }

  void updateError(BackupError error) {
    if (!mounted) {
      _logger.warning("Skip updateError: notifier disposed");
      return;
    }
    state = state.copyWith(error: error);
  }

  void updateSyncing(bool isSyncing) {
    state = state.copyWith(isSyncing: isSyncing);
  }

  @override
  void presentBackgroundSnapshot(EagerBackgroundUploadSnapshot snapshot) {
    if (!mounted) return;
    state = state.copyWith(isSyncing: snapshot.activeCount > 0, backgroundUploadSnapshot: snapshot);
  }

  @override
  void presentActivity(BackupUploadActivity activity) {
    if (!mounted) return;
    switch (activity.kind) {
      case BackupUploadActivityKind.status:
        return;
      case BackupUploadActivityKind.progress:
        final totalBytes = activity.totalBytes ?? 0;
        final bytes = totalBytes == 0 ? 0 : ((activity.progress ?? 0) * totalBytes).round();
        _handleForegroundBackupProgress(
          activity.localAssetId,
          activity.filename ?? '',
          bytes,
          totalBytes,
          progressOverride: activity.progress,
          requiresActiveForegroundRun: false,
        );
      case BackupUploadActivityKind.success:
        _handleForegroundBackupSuccess(activity.localAssetId, '');
      case BackupUploadActivityKind.iCloudProgress:
        _handleICloudProgress(activity.localAssetId, activity.progress ?? 0);
      case BackupUploadActivityKind.error:
        _handleForegroundBackupError(activity.localAssetId, activity.error ?? 'background_upload_failed');
    }
  }

  Future<void> startForegroundBackup(String userId) {
    // Cancel any existing backup before starting a new one
    if (_cancelToken != null) {
      stopForegroundBackup();
    }

    state = state.copyWith(error: BackupError.none, clearBackgroundUploadSnapshot: true);

    final runToken = Completer<void>();
    _cancelToken = runToken;

    return _foregroundUploadService
        .uploadCandidates(
          userId,
          runToken,
          callbacks: UploadCallbacks(
            onProgress: _handleForegroundBackupProgress,
            onSuccess: _handleForegroundBackupSuccess,
            onError: _handleForegroundBackupError,
            onICloudProgress: _handleICloudProgress,
          ),
        )
        .then<void>((_) {})
        .whenComplete(() {
          if (identical(_cancelToken, runToken)) {
            _cancelToken = null;
          }
        });
  }

  void stopForegroundBackup() {
    final token = _cancelToken;
    if (token != null && !token.isCompleted) token.complete();
    _cancelToken = null;
    _uploadSpeedManager.clear();
    state = state.copyWith(uploadItems: {}, iCloudDownloadProgress: {});
  }

  void _handleICloudProgress(String localAssetId, double progress) {
    state = state.copyWith(iCloudDownloadProgress: {...state.iCloudDownloadProgress, localAssetId: progress});

    if (progress >= 1.0) {
      Future.delayed(const Duration(milliseconds: 250), () {
        final updatedProgress = Map<String, double>.from(state.iCloudDownloadProgress);
        updatedProgress.remove(localAssetId);
        state = state.copyWith(iCloudDownloadProgress: updatedProgress);
      });
    }
  }

  void _handleForegroundBackupProgress(
    String localAssetId,
    String filename,
    int bytes,
    int totalBytes, {
    double? progressOverride,
    bool requiresActiveForegroundRun = true,
  }) {
    if (requiresActiveForegroundRun && _cancelToken == null) return;
    final progress = progressOverride ?? (totalBytes > 0 ? bytes / totalBytes : 0.0);
    final networkSpeedAsString = _uploadSpeedManager.updateProgress(localAssetId, bytes, totalBytes);
    final currentItem = state.uploadItems[localAssetId];
    if (currentItem != null) {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: currentItem.copyWith(
            filename: filename,
            progress: progress,
            fileSize: totalBytes,
            networkSpeedAsString: networkSpeedAsString,
          ),
        },
      );
    } else {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: DriftUploadStatus(
            taskId: localAssetId,
            filename: filename,
            progress: progress,
            fileSize: totalBytes,
            networkSpeedAsString: networkSpeedAsString,
          ),
        },
      );
    }
  }

  void _handleForegroundBackupSuccess(String localAssetId, String remoteAssetId) {
    final completed = state.remainderCount > 0 ? 1 : 0;
    state = state.copyWith(
      backupCount: state.backupCount + completed,
      remainderCount: state.remainderCount - completed,
    );
    _uploadSpeedManager.removeTask(localAssetId);

    Future.delayed(const Duration(milliseconds: 1000), () {
      _removeUploadItem(localAssetId);
    });
  }

  void _handleForegroundBackupError(String localAssetId, String errorMessage) {
    _logger.severe('foreground_upload_rejected');

    final currentItem = state.uploadItems[localAssetId];
    if (currentItem != null) {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: currentItem.copyWith(isFailed: true, error: errorMessage),
        },
      );
    } else {
      state = state.copyWith(
        uploadItems: {
          ...state.uploadItems,
          localAssetId: DriftUploadStatus(
            taskId: localAssetId,
            filename: 'Unknown',
            progress: 0,
            fileSize: 0,
            networkSpeedAsString: '',
            isFailed: true,
            error: errorMessage,
          ),
        },
      );
    }

    _uploadSpeedManager.removeTask(localAssetId);
  }

  Future<void> startBackupWithURLSession(String userId) async {
    if (!mounted) {
      _logger.warning("Skip handleBackupResume (pre-call): notifier disposed");
      return;
    }
    final binding = _bindings.capture();
    if (binding == null || binding.userId != userId) {
      _logger.info('background_backup_binding_unavailable');
      return;
    }
    final authority = await _enablementAuthority.readAuthority();
    if (authority?.phase != DurableBackupEnablementPhase.enabled) return;
    _logger.info("Start background backup sequence");
    state = state.copyWith(error: BackupError.none, clearBackgroundUploadSnapshot: true);
    final admission = await _arbiter.acquireBackground(bindingDigest: binding.digest);
    final lease = admission.lease;
    var ownershipTransferred = false;
    try {
      if (!mounted) {
        _logger.warning("Skip handleBackupResume (post-call): notifier disposed");
        return;
      }
      final currentAuthority = await _enablementAuthority.readAuthority();
      if (currentAuthority != authority || currentAuthority?.phase != DurableBackupEnablementPhase.enabled) return;
      if (admission.disposition == BackupAdmissionDisposition.adoptedBackground) {
        ownershipTransferred = true;
        if (lease == null || !_bindings.isCurrent(binding)) return;
        final owner = EagerBackgroundUploadOwner.fromLease(lease);
        final EagerBackgroundUploadSnapshot snapshot;
        try {
          snapshot = await _backgroundUploadService.readSnapshot(owner).timeout(_backgroundOwnerTimeout);
        } on TimeoutException {
          _logger.warning('background_backup_owner_snapshot_timed_out');
          return;
        }
        if (!mounted || !_bindings.isCurrent(binding)) return;
        final authorityAfterSnapshot = await _enablementAuthority.readAuthority();
        if (authorityAfterSnapshot != currentAuthority ||
            authorityAfterSnapshot?.phase != DurableBackupEnablementPhase.enabled ||
            !_bindings.isCurrent(binding)) {
          return;
        }
        presentBackgroundSnapshot(snapshot);
        if (snapshot.ownerState != EagerBackgroundOwnerState.active) return;
        try {
          await _backgroundUploadService.resumeOwned(owner).timeout(_backgroundOwnerTimeout);
        } on TimeoutException {
          _logger.warning('background_backup_owner_resume_timed_out');
          return;
        }
        if (!mounted || !_bindings.isCurrent(binding)) return;
        final authorityAfterResume = await _enablementAuthority.readAuthority();
        if (authorityAfterResume != authorityAfterSnapshot ||
            authorityAfterResume?.phase != DurableBackupEnablementPhase.enabled) {
          return;
        }
        return;
      }
      if (!admission.admitted || lease == null || !_bindings.isCurrent(binding)) return;
      ownershipTransferred = true;
      return _backgroundUploadService.uploadBackupCandidates(
        userId,
        binding: binding,
        lease: lease,
        isBindingCurrent: () => _bindings.isCurrent(binding),
      );
    } finally {
      if (!ownershipTransferred && admission.admitted && lease != null) {
        await _arbiter.releaseCurrentWhenQuiescent(runToken: lease.runToken, bindingDigest: lease.bindingDigest);
      }
    }
  }
}

final driftBackupCandidateProvider = FutureProvider.autoDispose<List<LocalAsset>>((ref) {
  final user = ref.watch(currentUserProvider);
  if (user == null) {
    return [];
  }

  return ref.read(foregroundUploadServiceProvider).getBackupCandidates(user.id, onlyHashed: false);
});

final driftCandidateBackupAlbumInfoProvider = FutureProvider.autoDispose.family<List<LocalAlbum>, String>((
  ref,
  assetId,
) {
  return ref.read(localAssetRepository).getSourceAlbums(assetId, backupSelection: BackupSelection.selected);
});
