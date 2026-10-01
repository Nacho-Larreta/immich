import 'dart:async';

import 'package:auto_route/auto_route.dart';
import 'package:background_downloader/background_downloader.dart';
import 'package:flutter/material.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/enums.dart';
import 'package:immich_mobile/domain/interfaces/share_operation.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/asset_edit.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_intent.model.dart';
import 'package:immich_mobile/domain/models/manual_upload_result.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/services/asset.service.dart';
import 'package:immich_mobile/domain/services/remote_mutation_guard.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/extensions/platform_extensions.dart';
import 'package:immich_mobile/models/download/livephotos_medatada.model.dart';
import 'package:immich_mobile/providers/asset_viewer/asset_viewer.provider.dart';
import 'package:immich_mobile/providers/backup/asset_upload_progress.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset.provider.dart';
import 'package:immich_mobile/providers/infrastructure/asset_viewer/asset.provider.dart' show assetExifProvider;
import 'package:immich_mobile/providers/manual_upload.provider.dart';
import 'package:immich_mobile/providers/server_access.provider.dart';
import 'package:immich_mobile/providers/timeline/multiselect.provider.dart';
import 'package:immich_mobile/providers/user.provider.dart';
import 'package:immich_mobile/providers/websocket.provider.dart';
import 'package:immich_mobile/routing/router.dart';
import 'package:immich_mobile/services/action.service.dart';
import 'package:immich_mobile/services/download.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/widgets/asset_grid/delete_dialog.dart';
import 'package:logging/logging.dart';
import 'package:openapi/api.dart';
import 'package:uuid/uuid.dart';

final actionProvider = NotifierProvider<ActionNotifier, void>(ActionNotifier.new, dependencies: [multiSelectProvider]);
final manualUploadDeviceIdProvider = Provider<String>((_) => Store.get(StoreKey.deviceId));

class ActionResult {
  final int count;
  final bool success;
  final String? error;
  final int failedCount;
  final int pendingCount;
  final int cancelledCount;
  final int acceptedCount;
  final List<String> acceptedIntentIds;
  final List<String> acceptedLocalAssetIds;

  const ActionResult({
    required this.count,
    required this.success,
    this.error,
    this.failedCount = 0,
    this.pendingCount = 0,
    this.cancelledCount = 0,
    this.acceptedCount = 0,
    this.acceptedIntentIds = const [],
    this.acceptedLocalAssetIds = const [],
  });

  @override
  String toString() =>
      'ActionResult(count: $count, success: $success, failed: $failedCount, pending: $pendingCount, '
      'cancelled: $cancelledCount, accepted: $acceptedCount, error: $error)';
}

class ActionNotifier extends Notifier<void> {
  final Logger _logger = Logger('ActionNotifier');
  late ActionService _service;
  late ForegroundUploadService _foregroundUploadService;
  late DownloadService _downloadService;
  late AssetService _assetService;
  late RemoteMutationGuard _remoteMutationGuard;

  ActionNotifier() : super();

  @override
  void build() {
    _foregroundUploadService = ref.watch(foregroundUploadServiceProvider);
    _service = ref.watch(actionServiceProvider);
    _assetService = ref.watch(assetServiceProvider);
    _downloadService = ref.watch(downloadServiceProvider);
    _remoteMutationGuard = ref.watch(remoteMutationGuardProvider);
    _downloadService.onImageDownloadStatus = _downloadImageCallback;
    _downloadService.onVideoDownloadStatus = _downloadVideoCallback;
    _downloadService.onLivePhotoDownloadStatus = _downloadLivePhotoCallback;
  }

  void _downloadImageCallback(TaskStatusUpdate update) {
    if (update.status == TaskStatus.complete) {
      _downloadService.saveImageWithPath(update.task);
    }
  }

  void _downloadVideoCallback(TaskStatusUpdate update) {
    if (update.status == TaskStatus.complete) {
      _downloadService.saveVideo(update.task);
    }
  }

  void _downloadLivePhotoCallback(TaskStatusUpdate update) async {
    if (update.status == TaskStatus.complete) {
      final livePhotosId = LivePhotosMetadata.fromJson(update.task.metaData).id;
      unawaited(_downloadService.saveLivePhotos(update.task, livePhotosId));
    }
  }

  List<String> _getRemoteIdsForSource(ActionSource source) {
    return _getAssets(source).whereType<RemoteAsset>().toIds().toList(growable: false);
  }

  List<String> _getLocalIdsForSource(ActionSource source, {bool ignoreLocalOnly = false}) {
    final Set<BaseAsset> assets = _getAssets(source);
    final List<String> localIds = [];

    for (final asset in assets) {
      if (ignoreLocalOnly && asset.storage != AssetState.merged) {
        continue;
      }
      if (asset is LocalAsset) {
        localIds.add(asset.id);
      } else if (asset is RemoteAsset && asset.localId != null) {
        localIds.add(asset.localId!);
      }
    }

    return localIds;
  }

  List<String> _getOwnedRemoteIdsForSource(ActionSource source) {
    final ownerId = ref.read(currentUserProvider)?.id;
    return _getAssets(source).whereType<RemoteAsset>().ownedAssets(ownerId).toIds().toList(growable: false);
  }

  List<RemoteAsset> _getOwnedRemoteAssetsForSource(ActionSource source) {
    final ownerId = ref.read(currentUserProvider)?.id;
    return _getIdsForSource<RemoteAsset>(source).ownedAssets(ownerId).toList();
  }

  Iterable<T> _getIdsForSource<T extends BaseAsset>(ActionSource source) {
    final Set<BaseAsset> assets = _getAssets(source);
    return switch (T) {
          const (RemoteAsset) => assets.whereType<RemoteAsset>(),
          const (LocalAsset) => assets.whereType<LocalAsset>(),
          _ => const [],
        }
        as Iterable<T>;
  }

  Set<BaseAsset> _getAssets(ActionSource source) {
    return switch (source) {
      ActionSource.timeline => ref.read(multiSelectProvider).selectedAssets,
      ActionSource.viewer => switch (ref.read(assetViewerProvider).currentAsset) {
        BaseAsset asset => {asset},
        null => const {},
      },
    };
  }

  Future<ActionResult> troubleshoot(ActionSource source, BuildContext context) async {
    final assets = _getAssets(source);
    if (assets.length > 1) {
      return ActionResult(count: assets.length, success: false, error: 'Cannot troubleshoot multiple assets');
    }
    unawaited(context.pushRoute(AssetTroubleshootRoute(asset: assets.first)));

    return ActionResult(count: assets.length, success: true);
  }

  Future<ActionResult> shareLink(ActionSource source, BuildContext context) async {
    final ids = _getRemoteIdsForSource(source);
    try {
      await _service.shareLink(ids, context);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to create shared link for assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> favorite(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.favorite(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to favorite assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> unFavorite(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.unFavorite(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to unfavorite assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> archive(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.archive(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to archive assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> unArchive(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.unArchive(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to unarchive assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> moveToLockFolder(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    final localIds = _getLocalIdsForSource(source, ignoreLocalOnly: true);
    try {
      await _service.moveToLockFolder(ids, localIds);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to move assets to lock folder', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> removeFromLockFolder(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.removeFromLockFolder(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to remove assets from lock folder', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> trash(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);

    try {
      await _service.trash(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to trash assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> restoreTrash(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.restoreTrash(ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to restore trash assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> trashRemoteAndDeleteLocal(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    final localIds = _getLocalIdsForSource(source);
    try {
      await _service.trashRemoteAndDeleteLocal(ids, localIds);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to delete assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> deleteRemoteAndLocal(ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    final localIds = _getLocalIdsForSource(source);
    try {
      await _service.deleteRemoteAndLocal(ids, localIds);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to delete assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult?> deleteLocal(ActionSource source, BuildContext context) async {
    final assets = _getAssets(source);
    bool? backedUpOnly = assets.every((asset) => asset.storage == AssetState.merged)
        ? true
        : await showDialog<bool>(
            context: context,
            builder: (BuildContext context) => DeleteLocalOnlyDialog(onDeleteLocal: (_) {}),
          );

    if (backedUpOnly == null) {
      // User cancelled the dialog
      return null;
    }

    final List<String> ids;
    if (backedUpOnly) {
      ids = assets.where((asset) => asset.storage == AssetState.merged).map((asset) => asset.localId!).toList();
    } else {
      ids = _getLocalIdsForSource(source);
    }

    try {
      final deletedCount = await _service.deleteLocal(ids);
      return ActionResult(count: deletedCount, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to delete assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult?> editLocation(ActionSource source, BuildContext context) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      final isEdited = await _service.editLocation(ids, context);
      if (!isEdited) {
        return null;
      }

      // This must be called since editing location
      // does not update the currentAsset which means
      // the exif provider will not be refreshed automatically
      if (source == ActionSource.viewer) {
        final currentAsset = ref.read(assetViewerProvider).currentAsset;
        if (currentAsset != null) {
          ref.invalidate(assetExifProvider(currentAsset));
        }
      }

      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to edit location for assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult?> editDateTime(ActionSource source, BuildContext context) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      final isEdited = await _service.editDateTime(ids, context);
      if (!isEdited) {
        return null;
      }

      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to edit date and time for assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> removeFromAlbum(ActionSource source, String albumId) async {
    final ids = _getRemoteIdsForSource(source);
    try {
      final removedCount = await _service.removeFromAlbum(ids, albumId);
      return ActionResult(count: removedCount, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to remove assets from album', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> setAlbumCover(ActionSource source, String albumId) async {
    final assets = _getAssets(source);
    final asset = assets.first;
    if (asset is! RemoteAsset) {
      return const ActionResult(count: 1, success: false, error: 'Asset must be remote');
    }

    try {
      await _service.setAlbumCover(albumId, asset.id);
      return const ActionResult(count: 1, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to set album cover', error, stack);
      return ActionResult(count: 1, success: false, error: error.toString());
    }
  }

  Future<ActionResult> updateDescription(ActionSource source, String description) async {
    final ids = _getRemoteIdsForSource(source);
    if (ids.length != 1) {
      _logger.warning('updateDescription called with multiple assets, expected single asset');
      return ActionResult(count: ids.length, success: false, error: 'Expected single asset for description update');
    }

    try {
      final isUpdated = await _service.updateDescription(ids.first, description);
      return ActionResult(count: 1, success: isUpdated);
    } catch (error, stack) {
      _logger.severe('Failed to update description for asset', error, stack);
      return ActionResult(count: 1, success: false, error: error.toString());
    }
  }

  Future<ActionResult> updateRating(ActionSource source, int rating) async {
    final ids = _getRemoteIdsForSource(source);
    if (ids.length != 1) {
      _logger.warning('updateRating called with multiple assets, expected single asset');
      return ActionResult(count: ids.length, success: false, error: 'Expected single asset for rating update');
    }

    try {
      final isUpdated = await _service.updateRating(ids.first, rating);
      return ActionResult(count: 1, success: isUpdated);
    } catch (error, stack) {
      _logger.severe('Failed to update rating for asset', error, stack);
      return ActionResult(count: 1, success: false, error: error.toString());
    }
  }

  Future<ActionResult> stack(String userId, ActionSource source) async {
    final ids = _getOwnedRemoteIdsForSource(source);
    try {
      await _service.stack(userId, ids);
      return ActionResult(count: ids.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to stack assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> unStack(ActionSource source) async {
    final assets = _getOwnedRemoteAssetsForSource(source);
    try {
      await _service.unStack(assets.map((e) => e.stackId).nonNulls.toList());
      if (source == ActionSource.viewer) {
        final updatedParent = await _assetService.getRemoteAsset(assets.first.id);
        if (updatedParent != null) {
          ref.read(assetViewerProvider.notifier).setAsset(updatedParent);
        }
      }

      return ActionResult(count: assets.length, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to unstack assets', error, stack);
      return ActionResult(count: assets.length, success: false);
    }
  }

  ShareOperation shareAssets(ActionSource source, {ShareAnchor? anchor}) {
    return _service.shareAssets(_getAssets(source).toList(growable: false), anchor: anchor);
  }

  Future<ActionResult> downloadAll(ActionSource source) async {
    final assets = _getAssets(source).whereType<RemoteAsset>().toList(growable: false);
    try {
      final didEnqueue = await _service.downloadAll(assets);
      final enqueueCount = didEnqueue.where((e) => e).length;
      return ActionResult(count: enqueueCount, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to download assets', error, stack);
      return ActionResult(count: assets.length, success: false, error: error.toString());
    }
  }

  Future<ActionResult> upload(ActionSource source, {List<LocalAsset>? assets}) async {
    final assetsToUpload = List<LocalAsset>.of(assets ?? _getAssets(source).whereType<LocalAsset>());
    if (assetsToUpload.isEmpty) {
      return const ActionResult(count: 0, success: true);
    }
    if (!CurrentPlatform.isIOS) return _uploadForeground(assetsToUpload);

    try {
      final destination = ref.read(manualUploadAuthorityProvider).currentDestination();
      if (destination == null) throw StateError('Manual upload destination unavailable');
      final deviceId = ref.read(manualUploadDeviceIdProvider);
      final selectedAt = DateTime.now().toUtc();
      const uuid = Uuid();
      final selections = [
        for (final asset in assetsToUpload)
          ManualUploadSelection(
            intentId: uuid.v4(),
            destination: destination,
            deviceId: deviceId,
            localAssetId: asset.id,
            createdAt: selectedAt,
          ),
      ];
      final accepted = await ref.read(manualUploadSubmissionProvider).submit(selections);
      final progressNotifier = ref.read(assetUploadProgressProvider.notifier);
      for (final intent in accepted) {
        progressNotifier.setProgress(intent.localAssetId, 0);
      }
      return ActionResult(
        count: 0,
        success: accepted.length == assetsToUpload.length,
        acceptedCount: accepted.length,
        acceptedIntentIds: [for (final intent in accepted) intent.id],
        acceptedLocalAssetIds: [for (final intent in accepted) intent.localAssetId],
        pendingCount: accepted.length,
      );
    } catch (error, stack) {
      _logger.severe('Failed to persist manual upload selection', error, stack);
      return ActionResult(count: 0, success: false, pendingCount: assetsToUpload.length, error: error.toString());
    }
  }

  Future<ActionResult> _uploadForeground(List<LocalAsset> assets) async {
    try {
      _remoteMutationGuard.requireAllowed();
    } on Object {
      return ActionResult(count: 0, success: false, pendingCount: assets.length, error: 'Remote upload unavailable');
    }
    final progress = ref.read(assetUploadProgressProvider.notifier);
    final cancelToken = Completer<void>();
    ref.read(manualUploadCancelTokenProvider.notifier).state = cancelToken;
    for (final asset in assets) {
      progress.setProgress(asset.id, 0);
    }
    try {
      final uploadResult = await _foregroundUploadService.uploadManual(
        assets,
        cancelToken: cancelToken,
        callbacks: UploadCallbacks(
          onProgress: (localAssetId, filename, bytes, totalBytes) {
            progress.setProgress(localAssetId, totalBytes > 0 ? bytes / totalBytes : 0);
          },
          onSuccess: (localAssetId, remoteAssetId) => progress.remove(localAssetId),
          onError: (localAssetId, errorMessage) => progress.setError(localAssetId),
        ),
      );
      for (final outcome in uploadResult.outcomes) {
        switch (outcome.state) {
          case ManualAssetUploadState.succeeded:
            progress.remove(outcome.localAssetId);
          case ManualAssetUploadState.failed:
            progress.setError(outcome.localAssetId);
          case ManualAssetUploadState.pending:
          case ManualAssetUploadState.cancelled:
            break;
        }
      }
      return ActionResult(
        count: uploadResult.succeededCount,
        success: uploadResult.requestedCount == assets.length && uploadResult.allSucceeded,
        failedCount: uploadResult.failedCount,
        pendingCount: uploadResult.pendingCount,
        cancelledCount: uploadResult.cancelledCount,
      );
    } on Object {
      return ActionResult(count: 0, success: false, pendingCount: assets.length, error: 'Manual upload failed');
    } finally {
      ref.read(manualUploadCancelTokenProvider.notifier).state = null;
    }
  }

  Future<ActionResult> applyEdits(ActionSource source, List<AssetEdit> edits) async {
    final ids = _getOwnedRemoteIdsForSource(source);

    if (ids.length != 1) {
      _logger.warning('applyEdits called with multiple assets, expected single asset');
      return ActionResult(count: ids.length, success: false, error: 'Expected single asset for applying edits');
    }

    final completer = ref.read(websocketProvider.notifier).waitForEvent("AssetEditReadyV1", (dynamic data) {
      final eventAsset = SyncAssetV1.fromJson(data["asset"]);
      return eventAsset?.id == ids.first;
    }, const Duration(seconds: 10));

    try {
      await _service.applyEdits(ids.first, edits);
      await completer;
      return const ActionResult(count: 1, success: true);
    } catch (error, stack) {
      _logger.severe('Failed to apply edits to assets', error, stack);
      return ActionResult(count: ids.length, success: false, error: error.toString());
    }
  }
}

extension on Iterable<RemoteAsset> {
  Iterable<String> toIds() => map((e) => e.id);

  Iterable<RemoteAsset> ownedAssets(String? ownerId) {
    if (ownerId == null) return const [];
    return whereType<RemoteAsset>().where((a) => a.ownerId == ownerId);
  }
}
