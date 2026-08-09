import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_asset_management.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/share_operation.interface.dart';
import 'package:immich_mobile/domain/interfaces/share_sheet.interface.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';
import 'package:immich_mobile/infrastructure/adapters/local_asset_management/photo_manager_local_asset_management_adapter.dart';
import 'package:immich_mobile/providers/original_export.provider.dart';
import 'package:immich_mobile/providers/share_sheet.provider.dart';

typedef RemoteOriginalUriBuilder = Uri? Function(String assetId, {required bool edited});

final assetMediaRepositoryProvider = Provider((ref) {
  final repository = AssetMediaRepository(
    localExporter: ref.read(localOriginalExportProvider),
    remoteExporter: ref.read(remoteOriginalExportProvider),
    shareSheet: ref.read(shareSheetProvider),
    buildRemoteOriginalUri: ref.read(remoteOriginalUriBuilderProvider),
    localAssets: PhotoManagerLocalAssetManagementAdapter(),
  );
  ref.onDispose(() => unawaited(repository.dispose()));
  return repository;
});

class AssetMediaRepository {
  final LocalOriginalExportPort _localExporter;
  final RemoteOriginalExportPort _remoteExporter;
  final ShareSheetPort _shareSheet;
  final RemoteOriginalUriBuilder _buildRemoteOriginalUri;
  final LocalAssetManagementPort _localAssets;
  final Set<_AssetShareOperation> _shareOperations = {};
  bool _acceptingShares = true;
  bool _disposed = false;

  AssetMediaRepository({
    required LocalOriginalExportPort localExporter,
    required RemoteOriginalExportPort remoteExporter,
    required ShareSheetPort shareSheet,
    required RemoteOriginalUriBuilder buildRemoteOriginalUri,
    required LocalAssetManagementPort localAssets,
  }) : _localExporter = localExporter,
       _remoteExporter = remoteExporter,
       _shareSheet = shareSheet,
       _buildRemoteOriginalUri = buildRemoteOriginalUri,
       _localAssets = localAssets;

  Future<List<String>> deleteAll(List<String> ids) async {
    return _localAssets.deleteAll(ids);
  }

  Future<String?> getOriginalFilename(String id) async {
    return _localAssets.getOriginalFilename(id);
  }

  ShareOperation shareAssets(List<BaseAsset> assets, {ShareAnchor? anchor}) {
    if (!_acceptingShares || _disposed) {
      return const _RejectedShareOperation();
    }
    final operation = _AssetShareOperation(
      assets: List.unmodifiable(assets),
      anchor: anchor,
      localExporter: _localExporter,
      remoteExporter: _remoteExporter,
      shareSheet: _shareSheet,
      buildRemoteOriginalUri: _buildRemoteOriginalUri,
      onFinished: _shareOperations.remove,
    );
    _shareOperations.add(operation);
    operation.start();
    return operation;
  }

  Future<void> cancelAll() async {
    _acceptingShares = false;
    final operations = _shareOperations.toList(growable: false);
    await Future.wait(operations.map((operation) => operation.cancel()));
    await Future.wait(
      operations.where((operation) => !operation.isPresentationOwned).map((operation) => operation.result),
    );
  }

  void activateSession() {
    if (!_disposed) {
      _acceptingShares = true;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    await cancelAll();
  }
}

final class _AssetShareOperation implements ShareOperation {
  _AssetShareOperation({
    required this.assets,
    required this.anchor,
    required LocalOriginalExportPort localExporter,
    required RemoteOriginalExportPort remoteExporter,
    required ShareSheetPort shareSheet,
    required RemoteOriginalUriBuilder buildRemoteOriginalUri,
    required void Function(_AssetShareOperation operation) onFinished,
  }) : _localExporter = localExporter,
       _remoteExporter = remoteExporter,
       _shareSheet = shareSheet,
       _buildRemoteOriginalUri = buildRemoteOriginalUri,
       _onFinished = onFinished;

  final List<BaseAsset> assets;
  final ShareAnchor? anchor;
  final LocalOriginalExportPort _localExporter;
  final RemoteOriginalExportPort _remoteExporter;
  final ShareSheetPort _shareSheet;
  final RemoteOriginalUriBuilder _buildRemoteOriginalUri;
  final void Function(_AssetShareOperation operation) _onFinished;
  final Completer<ShareResult> _result = Completer();
  final StreamController<ShareProgress> _progress = StreamController.broadcast(sync: true);
  final List<({String assetId, TemporaryFileLease lease})> _leases = [];
  CancellableRequest<Object?>? _activeRequest;
  Future<void>? _cancelFuture;
  bool _cancelled = false;
  bool _presentationOwned = false;

  bool get isPresentationOwned => _presentationOwned;

  @override
  Future<ShareResult> get result => _result.future;

  @override
  Stream<ShareProgress> get progress => _progress.stream;

  void start() => unawaited(_run());

  @override
  Future<void> cancel() => _cancelFuture ??= _cancelOnce();

  Future<void> _cancelOnce() async {
    _cancelled = true;
    if (_presentationOwned) {
      return;
    }
    await _activeRequest?.cancel();
  }

  Future<void> _run() async {
    ShareResult outcome;
    try {
      outcome = assets.isEmpty
          ? const ShareResult.failure(ShareSheetFailure(error: ShareSheetError.unavailable))
          : await _prepareAndShare();
    } on Object {
      outcome = ShareResult.failure(
        ShareAssetFailure(
          assetId: _assetIdentity(assets.first),
          phase: SharePhase.cleanup,
          error: OriginalExportError.writeFailed,
        ),
      );
    }

    final cleanupFailure = await _cleanup();
    if (_cancelled && _presentationOwned && assets.isNotEmpty) {
      outcome = _cancelledResult(assets.first, SharePhase.cleanup);
    } else if (cleanupFailure != null) {
      outcome = ShareResult.failure(cleanupFailure);
    } else if (_cancelled && assets.isNotEmpty) {
      outcome = ShareResult.failure(
        ShareAssetFailure(
          assetId: _assetIdentity(assets.first),
          phase: SharePhase.cleanup,
          error: OriginalExportError.cancelled,
        ),
      );
    }
    _result.complete(outcome);
    await _progress.close();
    _onFinished(this);
  }

  Future<ShareResult> _prepareAndShare() async {
    for (final (index, asset) in assets.indexed) {
      if (_cancelled) {
        return _cancelledResult(asset, _phaseFor(asset));
      }
      final phase = _phaseFor(asset);
      _publish(phase, index);
      final request = _export(asset);
      _activeRequest = request;
      final exportResult = await request.result;
      _activeRequest = null;
      if (exportResult case OriginalExportFailure(:final error)) {
        return ShareResult.failure(ShareAssetFailure(assetId: _assetIdentity(asset), phase: phase, error: error));
      }
      final lease = (exportResult as OriginalExportSuccess).lease;
      _leases.add((assetId: _assetIdentity(asset), lease: lease));
      if (_cancelled) {
        return _cancelledResult(asset, phase);
      }
      _publish(phase, index + 1);
    }

    _publish(SharePhase.presentation, assets.length);
    final presentation = _shareSheet.share(
      ShareSheetRequest(paths: _leases.map((entry) => entry.lease.path), anchor: anchor),
    );
    _presentationOwned = true;
    _activeRequest = presentation;
    final result = await presentation.result;
    _activeRequest = null;
    return result;
  }

  CancellableRequest<OriginalExportResult> _export(BaseAsset asset) {
    final localId = asset.localId;
    if (localId != null && !asset.isEdited) {
      return _localExporter.export(
        LocalOriginalExportRequest(
          assetId: localId,
          suggestedFilename: asset.name,
          policy: LocalOriginalExportPolicy.allowICloud,
        ),
      );
    }

    final remoteId = asset.remoteId;
    final resource = remoteId == null ? null : _buildRemoteOriginalUri(remoteId, edited: asset.isEdited);
    if (remoteId == null || resource == null) {
      return const _CompletedOriginalExportRequest(OriginalExportResult.failure(OriginalExportError.assetMissing));
    }
    return _remoteExporter.export(RemoteOriginalExportRequest(resource: resource, suggestedFilename: asset.name));
  }

  SharePhase _phaseFor(BaseAsset asset) {
    return asset.localId != null && !asset.isEdited ? SharePhase.localExport : SharePhase.remoteExport;
  }

  Future<ShareAssetFailure?> _cleanup() async {
    if (assets.isNotEmpty) {
      _publish(SharePhase.cleanup, assets.length);
    }
    ShareAssetFailure? firstFailure;
    for (final entry in _leases) {
      try {
        await entry.lease.release();
      } on Object {
        firstFailure ??= ShareAssetFailure(
          assetId: entry.assetId,
          phase: SharePhase.cleanup,
          error: OriginalExportError.cleanupFailed,
        );
      }
    }
    return firstFailure;
  }

  void _publish(SharePhase phase, int completedCount) {
    if (!_progress.isClosed) {
      _progress.add(ShareProgress(phase: phase, completedCount: completedCount, totalCount: assets.length));
    }
  }

  ShareResult _cancelledResult(BaseAsset asset, SharePhase phase) {
    return ShareResult.failure(
      ShareAssetFailure(assetId: _assetIdentity(asset), phase: phase, error: OriginalExportError.cancelled),
    );
  }

  static String _assetIdentity(BaseAsset asset) => asset.localId ?? asset.remoteId ?? asset.name;
}

final class _RejectedShareOperation implements ShareOperation {
  const _RejectedShareOperation();

  @override
  Stream<ShareProgress> get progress => const Stream.empty();

  @override
  Future<ShareResult> get result => Future.value(
    ShareResult.failure(
      ShareAssetFailure(assetId: 'share-session', phase: SharePhase.cleanup, error: OriginalExportError.cancelled),
    ),
  );

  @override
  Future<void> cancel() async {}
}

final class _CompletedOriginalExportRequest implements CancellableRequest<OriginalExportResult> {
  const _CompletedOriginalExportRequest(this.value);

  final OriginalExportResult value;

  @override
  Future<OriginalExportResult> get result => Future.value(value);

  @override
  Future<void> cancel() async {}
}
