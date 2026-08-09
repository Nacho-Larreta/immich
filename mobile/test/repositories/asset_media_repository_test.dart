import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/local_asset_management.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/share_sheet.interface.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/asset/base_asset.model.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/share.model.dart';
import 'package:immich_mobile/repositories/asset_media.repository.dart';

void main() {
  group('AssetMediaRepository.shareAssets', () {
    test('returns a typed local failure and never presents a partial share', () async {
      final local = _LocalExporter([const OriginalExportResult.failure(OriginalExportError.assetMissing)]);
      final sheet = _ShareSheet();
      final repository = _repository(local: local, sheet: sheet);

      final result = await repository.shareAssets([_localAsset('missing')]).result;

      expect(
        result,
        ShareResult.failure(
          ShareAssetFailure(assetId: 'missing', phase: SharePhase.localExport, error: OriginalExportError.assetMissing),
        ),
      );
      expect(sheet.requests, isEmpty);
    });

    test('second export failure cleans the first lease and invokes no share sheet', () async {
      final firstLease = _Lease('/tmp/immich-share-one/photo.jpg');
      final local = _LocalExporter([
        OriginalExportResult.success(firstLease),
        const OriginalExportResult.failure(OriginalExportError.iCloudUnavailable),
      ]);
      final sheet = _ShareSheet();
      final repository = _repository(local: local, sheet: sheet);

      final result = await repository.shareAssets([_localAsset('one'), _localAsset('two')]).result;

      expect(result, isA<FailedShareResult>());
      expect(firstLease.releaseCount, 1);
      expect(sheet.requests, isEmpty);
    });

    test('cancel aborts the active export exactly once and cleans a late lease', () async {
      final controlled = _ControlledRequest<OriginalExportResult>();
      final local = _LocalExporter([], controlled: controlled);
      final repository = _repository(local: local);
      final operation = repository.shareAssets([_localAsset('one')]);
      await pumpEventQueue();

      final firstCancel = operation.cancel();
      final secondCancel = operation.cancel();
      await Future.wait([firstCancel, secondCancel]);
      final lateLease = _Lease('/tmp/immich-share-late/photo.jpg');
      controlled.complete(OriginalExportResult.success(lateLease));
      final result = await operation.result;

      expect(controlled.cancelCount, 1);
      expect(result, isA<FailedShareResult>());
      expect(lateLease.releaseCount, 1);
    });

    test('keeps every lease alive until share settles and cleans success, dismiss and error', () async {
      for (final sheetResult in <ShareResult>[
        ShareResult.success(actualCount: 2, disposition: ShareDisposition.completed),
        ShareResult.success(actualCount: 2, disposition: ShareDisposition.dismissed),
        const ShareResult.failure(ShareSheetFailure(error: ShareSheetError.presentationFailed)),
      ]) {
        final firstLease = _Lease('/tmp/immich-share-a/same.jpg');
        final secondLease = _Lease('/tmp/immich-share-b/same.jpg');
        final presentation = _ControlledRequest<ShareResult>();
        final sheet = _ShareSheet(controlled: presentation);
        final repository = _repository(
          local: _LocalExporter([OriginalExportResult.success(firstLease), OriginalExportResult.success(secondLease)]),
          sheet: sheet,
        );

        final operation = repository.shareAssets([_localAsset('one'), _localAsset('two')]);
        await pumpEventQueue();
        expect(firstLease.isAvailable, isTrue);
        expect(secondLease.isAvailable, isTrue);
        expect(sheet.requests.single.paths, [firstLease.path, secondLease.path]);

        presentation.complete(sheetResult);
        expect(await operation.result, sheetResult);
        expect(firstLease.isAvailable, isFalse);
        expect(secondLease.isAvailable, isFalse);
      }
    });

    test('reports cleanup failure instead of claiming share success', () async {
      final lease = _Lease('/tmp/immich-share-fail/photo.jpg', failRelease: true);
      final repository = _repository(
        local: _LocalExporter([OriginalExportResult.success(lease)]),
        sheet: _ShareSheet(result: ShareResult.success(actualCount: 1, disposition: ShareDisposition.completed)),
      );

      final result = await repository.shareAssets([_localAsset('one')]).result;

      expect(
        result,
        ShareResult.failure(
          ShareAssetFailure(assetId: 'one', phase: SharePhase.cleanup, error: OriginalExportError.cleanupFailed),
        ),
      );
    });

    test('cancel during cleanup waits for the lease and returns a typed cancellation', () async {
      final release = Completer<void>();
      final lease = _Lease('/tmp/immich-share-cleanup/photo.jpg', releaseGate: release);
      final repository = _repository(
        local: _LocalExporter([OriginalExportResult.success(lease)]),
        sheet: _ShareSheet(result: ShareResult.success(actualCount: 1, disposition: ShareDisposition.completed)),
      );
      final operation = repository.shareAssets([_localAsset('one')]);
      await lease.releaseStarted.future;

      await operation.cancel();
      var completed = false;
      unawaited(operation.result.then((_) => completed = true));
      await pumpEventQueue();
      expect(completed, isFalse);

      release.complete();
      final result = await operation.result;
      expect(
        result,
        ShareResult.failure(
          ShareAssetFailure(assetId: 'one', phase: SharePhase.cleanup, error: OriginalExportError.cancelled),
        ),
      );
      expect(lease.releaseCount, 1);
    });

    test('session cancellation returns while the native sheet owns files, then cleans on settlement', () async {
      final lease = _Lease('/tmp/immich-share-owned/photo.jpg');
      final presentation = _ControlledRequest<ShareResult>();
      final local = _LocalExporter([OriginalExportResult.success(lease)]);
      final repository = _repository(
        local: local,
        sheet: _ShareSheet(controlled: presentation),
      );
      final operation = repository.shareAssets([_localAsset('one')]);
      await pumpEventQueue();

      await repository.cancelAll().timeout(const Duration(seconds: 1));
      expect(lease.isAvailable, isTrue);

      final rejected = await repository.shareAssets([_localAsset('rejected')]).result;
      expect((rejected as FailedShareResult).error, isA<ShareAssetFailure>());
      expect(local.requests, hasLength(1));

      presentation.complete(ShareResult.success(actualCount: 1, disposition: ShareDisposition.dismissed));
      expect(await operation.result, isA<FailedShareResult>());
      expect(lease.isAvailable, isFalse);

      repository.activateSession();
      local.results.add(OriginalExportResult.success(_Lease('/tmp/immich-share-reactivated/photo.jpg')));
      expect(await repository.shareAssets([_localAsset('reactivated')]).result, isA<SuccessfulShareResult>());
    });

    test('merged unedited prefers local while edited uses the remote original endpoint', () async {
      final local = _LocalExporter([OriginalExportResult.success(_Lease('/tmp/immich-share-local/photo.jpg'))]);
      final remote = _RemoteExporter([OriginalExportResult.success(_Lease('/tmp/immich-share-remote/photo.jpg'))]);
      final sheet = _ShareSheet(result: ShareResult.success(actualCount: 2, disposition: ShareDisposition.unknown));
      final repository = _repository(local: local, remote: remote, sheet: sheet);

      final result = await repository.shareAssets([
        _localAsset('local', remoteId: 'remote-local'),
        _localAsset('edited', remoteId: 'remote-edited', isEdited: true),
      ]).result;

      expect(local.requests.map((request) => request.assetId), ['local']);
      expect(remote.requests.single.resource.path, '/api/assets/remote-edited/original');
      expect(result, ShareResult.success(actualCount: 2, disposition: ShareDisposition.unknown));
    });
  });
}

AssetMediaRepository _repository({_LocalExporter? local, _RemoteExporter? remote, _ShareSheet? sheet}) {
  return AssetMediaRepository(
    localExporter: local ?? _LocalExporter([]),
    remoteExporter: remote ?? _RemoteExporter([]),
    shareSheet: sheet ?? _ShareSheet(),
    buildRemoteOriginalUri: (id, {required edited}) =>
        Uri.parse('https://photos.test/api/assets/$id/original?edited=$edited'),
    localAssets: _LocalAssetManagement(),
  );
}

final class _LocalAssetManagement implements LocalAssetManagementPort {
  @override
  Future<List<String>> deleteAll(List<String> assetIds) async => assetIds;

  @override
  Future<String?> getOriginalFilename(String assetId) async => null;
}

LocalAsset _localAsset(String id, {String? remoteId, bool isEdited = false}) {
  return LocalAsset(
    id: id,
    remoteId: remoteId,
    name: 'same.jpg',
    type: AssetType.image,
    createdAt: DateTime(2026),
    updatedAt: DateTime(2026),
    playbackStyle: AssetPlaybackStyle.image,
    isEdited: isEdited,
  );
}

final class _LocalExporter implements LocalOriginalExportPort {
  _LocalExporter(this.results, {this.controlled});

  final List<OriginalExportResult> results;
  final _ControlledRequest<OriginalExportResult>? controlled;
  final List<LocalOriginalExportRequest> requests = [];

  @override
  CancellableRequest<OriginalExportResult> export(LocalOriginalExportRequest request) {
    requests.add(request);
    return controlled ?? _CompletedRequest(results.removeAt(0));
  }
}

final class _RemoteExporter implements RemoteOriginalExportPort {
  _RemoteExporter(this.results);

  final List<OriginalExportResult> results;
  final List<RemoteOriginalExportRequest> requests = [];

  @override
  CancellableRequest<OriginalExportResult> export(RemoteOriginalExportRequest request) {
    requests.add(request);
    return _CompletedRequest(results.removeAt(0));
  }
}

final class _ShareSheet implements ShareSheetPort {
  _ShareSheet({this.result, this.controlled});

  final ShareResult? result;
  final _ControlledRequest<ShareResult>? controlled;
  final List<ShareSheetRequest> requests = [];

  @override
  CancellableRequest<ShareResult> share(ShareSheetRequest request) {
    requests.add(request);
    return controlled ??
        _CompletedRequest(
          result ?? ShareResult.success(actualCount: request.paths.length, disposition: ShareDisposition.completed),
        );
  }
}

final class _CompletedRequest<T> implements CancellableRequest<T> {
  const _CompletedRequest(this.value);

  final T value;

  @override
  Future<T> get result => Future.value(value);

  @override
  Future<void> cancel() async {}
}

final class _ControlledRequest<T> implements CancellableRequest<T> {
  final Completer<T> _result = Completer();
  int cancelCount = 0;

  @override
  Future<T> get result => _result.future;

  void complete(T value) => _result.complete(value);

  @override
  Future<void> cancel() async {
    cancelCount++;
  }
}

final class _Lease extends TemporaryFileLease {
  _Lease(String path, {this.failRelease = false, this.releaseGate})
    : super(path: path, ownership: TemporaryFileOwnership.caller);

  final bool failRelease;
  final Completer<void>? releaseGate;
  final Completer<void> releaseStarted = Completer();
  int releaseCount = 0;
  bool isAvailable = true;

  @override
  Future<void> releaseResource() async {
    releaseCount++;
    if (!releaseStarted.isCompleted) {
      releaseStarted.complete();
    }
    await releaseGate?.future;
    if (failRelease) {
      throw StateError('cleanup failed');
    }
    isAvailable = false;
  }
}
