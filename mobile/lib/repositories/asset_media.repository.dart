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
  bool _acceptingRemoteShares = false;
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
    final immutableAssets = List<BaseAsset>.unmodifiable(assets);
    if (_disposed && immutableAssets.isNotEmpty) {
      return _RejectedShareOperation(_cancelledFailure(immutableAssets.first));
    }
    final plan = _compileSharePlan(immutableAssets);
    if (plan case _RejectedSharePlan(:final failure)) {
      return _RejectedShareOperation(failure);
    }
    final operation = _AssetShareOperation(
      plan: plan as _AcceptedSharePlan,
      anchor: anchor,
      localExporter: _localExporter,
      remoteExporter: _remoteExporter,
      shareSheet: _shareSheet,
      onFinished: _shareOperations.remove,
    );
    _shareOperations.add(operation);
    operation.start();
    return operation;
  }

  _SharePlan _compileSharePlan(List<BaseAsset> assets) {
    final steps = <_ShareExportStep>[];
    for (final asset in assets) {
      if (_usesLocalOriginal(asset)) {
        steps.add(_LocalShareExportStep(asset));
        continue;
      }

      final remoteId = asset.remoteId;
      if (remoteId == null) {
        return _RejectedSharePlan(_remoteFailure(asset, OriginalExportError.assetMissing));
      }
      if (!_acceptingRemoteShares) {
        return _RejectedSharePlan(_remoteFailure(asset, OriginalExportError.unauthorized));
      }

      Uri? resource;
      try {
        resource = _buildRemoteOriginalUri(remoteId, edited: asset.isEdited);
      } on Object {
        return _RejectedSharePlan(_remoteFailure(asset, OriginalExportError.serverUnavailable));
      }
      if (resource == null) {
        return _RejectedSharePlan(_remoteFailure(asset, OriginalExportError.serverUnavailable));
      }
      steps.add(_RemoteShareExportStep(asset, resource));
    }
    return _AcceptedSharePlan(assets: assets, steps: List.unmodifiable(steps));
  }

  Future<void> suspendRemoteShares() {
    _acceptingRemoteShares = false;
    return _cancelOperations((operation) => operation.usesRemote && !operation.isPresentationOwned);
  }

  Future<void> cancelAll() async {
    final operations = _shareOperations.toList(growable: false);
    await Future.wait(operations.map((operation) => operation.cancel()));
    await Future.wait(
      operations.where((operation) => !operation.isPresentationOwned).map((operation) => operation.result),
    );
  }

  Future<void> _cancelOperations(bool Function(_AssetShareOperation operation) shouldCancel) async {
    final operations = _shareOperations.where(shouldCancel).toList(growable: false);
    await Future.wait(operations.map((operation) => operation.cancel()));
    await Future.wait(operations.map((operation) => operation.result));
  }

  void activateRemoteShares() {
    if (!_disposed) {
      _acceptingRemoteShares = true;
    }
  }

  Future<void> dispose() async {
    _disposed = true;
    _acceptingRemoteShares = false;
    await cancelAll();
  }

  static bool _usesLocalOriginal(BaseAsset asset) => asset.localId != null && !asset.isEdited;

  static ShareAssetFailure _remoteFailure(BaseAsset asset, OriginalExportError error) {
    return ShareAssetFailure(
      assetId: _assetIdentityForPhase(asset, SharePhase.remoteExport),
      phase: SharePhase.remoteExport,
      error: error,
    );
  }

  static ShareAssetFailure _cancelledFailure(BaseAsset asset) {
    final phase = _usesLocalOriginal(asset) ? SharePhase.localExport : SharePhase.remoteExport;
    return ShareAssetFailure(
      assetId: _assetIdentityForPhase(asset, phase),
      phase: phase,
      error: OriginalExportError.cancelled,
    );
  }
}

final class _AssetShareOperation implements ShareOperation {
  _AssetShareOperation({
    required this.plan,
    required this.anchor,
    required LocalOriginalExportPort localExporter,
    required RemoteOriginalExportPort remoteExporter,
    required ShareSheetPort shareSheet,
    required void Function(_AssetShareOperation operation) onFinished,
  }) : _localExporter = localExporter,
       _remoteExporter = remoteExporter,
       _shareSheet = shareSheet,
       _onFinished = onFinished;

  final _AcceptedSharePlan plan;
  final ShareAnchor? anchor;
  final LocalOriginalExportPort _localExporter;
  final RemoteOriginalExportPort _remoteExporter;
  final ShareSheetPort _shareSheet;
  final void Function(_AssetShareOperation operation) _onFinished;
  final Completer<ShareResult> _result = Completer();
  final StreamController<ShareProgress> _progress = StreamController.broadcast(sync: true);
  final List<({String assetId, TemporaryFileLease lease, OriginalExportPresentationClaim? presentationClaim})> _leases =
      [];
  CancellableRequest<Object?>? _activeRequest;
  Future<void>? _cancelFuture;
  bool _cancelled = false;
  bool _presentationOwned = false;

  bool get isPresentationOwned => _presentationOwned;
  bool get usesRemote => plan.steps.any((step) => step is _RemoteShareExportStep);

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
      outcome = plan.assets.isEmpty
          ? const ShareResult.failure(ShareSheetFailure(error: ShareSheetError.unavailable))
          : await _prepareAndShare();
    } on Object {
      outcome = ShareResult.failure(
        ShareAssetFailure(
          assetId: _assetIdentityForPhase(plan.assets.first, SharePhase.cleanup),
          phase: SharePhase.cleanup,
          error: OriginalExportError.writeFailed,
        ),
      );
    }

    final cleanupFailure = await _cleanup();
    if (cleanupFailure != null) {
      outcome = ShareResult.failure(cleanupFailure);
    } else if (_cancelled && plan.assets.isNotEmpty && !_isCancellation(outcome)) {
      outcome = _cancelledResult(plan.assets.first, SharePhase.cleanup);
    }
    _result.complete(outcome);
    await _progress.close();
    _onFinished(this);
  }

  Future<ShareResult> _prepareAndShare() async {
    for (final (index, step) in plan.steps.indexed) {
      final asset = step.asset;
      if (_cancelled) {
        return _cancelledResult(asset, step.phase);
      }
      final phase = step.phase;
      _publish(phase, index);
      final request = _export(step);
      _activeRequest = request;
      final exportResult = await request.result;
      _activeRequest = null;
      if (exportResult case OriginalExportFailure(:final error)) {
        return ShareResult.failure(
          ShareAssetFailure(assetId: _assetIdentityForPhase(asset, phase), phase: phase, error: error),
        );
      }
      final success = exportResult as OriginalExportSuccess;
      _leases.add((
        assetId: _assetIdentityForPhase(asset, phase),
        lease: success.lease,
        presentationClaim: success.presentationClaim,
      ));
      if (_cancelled) {
        return _cancelledResult(asset, phase);
      }
      _publish(phase, index + 1);
    }

    _publish(SharePhase.presentation, plan.assets.length);
    if (!_claimPresentationOwnership()) {
      return const ShareResult.failure(ShareSheetFailure(error: ShareSheetError.presentationFailed));
    }
    _presentationOwned = true;
    final presentation = _shareSheet.share(
      ShareSheetRequest(paths: _leases.map((entry) => entry.lease.path), anchor: anchor),
    );
    _activeRequest = presentation;
    final result = await presentation.result;
    _activeRequest = null;
    return result;
  }

  bool _claimPresentationOwnership() {
    for (final entry in _leases) {
      final claim = entry.presentationClaim;
      if (claim != null && !claim.claim()) {
        return false;
      }
    }
    return !_cancelled;
  }

  CancellableRequest<OriginalExportResult> _export(_ShareExportStep step) {
    final asset = step.asset;
    if (step case _LocalShareExportStep()) {
      return _localExporter.export(
        LocalOriginalExportRequest(
          assetId: asset.localId!,
          suggestedFilename: asset.name,
          policy: LocalOriginalExportPolicy.allowICloud,
        ),
      );
    }
    final remote = step as _RemoteShareExportStep;
    return _remoteExporter.export(
      RemoteOriginalExportRequest(resource: remote.resource, suggestedFilename: asset.name),
    );
  }

  Future<ShareAssetFailure?> _cleanup() async {
    if (plan.assets.isNotEmpty) {
      _publish(SharePhase.cleanup, plan.assets.length);
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
      _progress.add(ShareProgress(phase: phase, completedCount: completedCount, totalCount: plan.assets.length));
    }
  }

  ShareResult _cancelledResult(BaseAsset asset, SharePhase phase) {
    return ShareResult.failure(
      ShareAssetFailure(
        assetId: _assetIdentityForPhase(asset, phase),
        phase: phase,
        error: OriginalExportError.cancelled,
      ),
    );
  }

  static bool _isCancellation(ShareResult result) {
    return result is FailedShareResult &&
        result.error is ShareAssetFailure &&
        (result.error as ShareAssetFailure).error == OriginalExportError.cancelled;
  }
}

String _assetIdentityForPhase(BaseAsset asset, SharePhase phase) {
  return phase == SharePhase.remoteExport
      ? asset.remoteId ?? asset.localId ?? asset.name
      : asset.localId ?? asset.remoteId ?? asset.name;
}

final class _RejectedShareOperation implements ShareOperation {
  const _RejectedShareOperation(this.failure);

  final ShareAssetFailure failure;

  @override
  Stream<ShareProgress> get progress => const Stream.empty();

  @override
  Future<ShareResult> get result => Future.value(ShareResult.failure(failure));

  @override
  Future<void> cancel() async {}
}

sealed class _SharePlan {
  const _SharePlan();
}

final class _AcceptedSharePlan extends _SharePlan {
  const _AcceptedSharePlan({required this.assets, required this.steps});

  final List<BaseAsset> assets;
  final List<_ShareExportStep> steps;
}

final class _RejectedSharePlan extends _SharePlan {
  const _RejectedSharePlan(this.failure);

  final ShareAssetFailure failure;
}

sealed class _ShareExportStep {
  const _ShareExportStep(this.asset);

  final BaseAsset asset;
  SharePhase get phase;
}

final class _LocalShareExportStep extends _ShareExportStep {
  const _LocalShareExportStep(super.asset);

  @override
  SharePhase get phase => SharePhase.localExport;
}

final class _RemoteShareExportStep extends _ShareExportStep {
  const _RemoteShareExportStep(super.asset, this.resource);

  final Uri resource;

  @override
  SharePhase get phase => SharePhase.remoteExport;
}
