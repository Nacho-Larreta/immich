import 'dart:async';

import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/interfaces/reconciliation.interface.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';

typedef ReconciliationSnapshotReader = ReconciliationSnapshot Function();

final class ReconciliationSnapshot {
  const ReconciliationSnapshot({required this.syncAlbums, required this.backupEnabled, required this.userId});

  final bool syncAlbums;
  final bool backupEnabled;
  final String? userId;
}

final class ServerReconciliationAdapter implements ReconciliationPort {
  const ServerReconciliationAdapter({
    required SessionEpochController epochs,
    required ReconciliationSnapshotReader readSnapshot,
    required void Function() disconnectWebsocket,
    required void Function() connectWebsocket,
    required Future<bool> Function() syncRemote,
    required Future<void> Function() hashAssets,
    required Future<void> Function() syncLinkedAlbums,
    required Future<void> Function(String userId) startBackup,
    required void Function() stopBackup,
    required Future<void> Function() cancelRemoteWork,
    required Future<void> Function() cancelLocalWork,
  }) : _epochs = epochs,
       _readSnapshot = readSnapshot,
       _disconnectWebsocket = disconnectWebsocket,
       _connectWebsocket = connectWebsocket,
       _syncRemote = syncRemote,
       _hashAssets = hashAssets,
       _syncLinkedAlbums = syncLinkedAlbums,
       _startBackup = startBackup,
       _stopBackup = stopBackup,
       _cancelRemoteWork = cancelRemoteWork,
       _cancelLocalWork = cancelLocalWork;

  final SessionEpochController _epochs;
  final ReconciliationSnapshotReader _readSnapshot;
  final void Function() _disconnectWebsocket;
  final void Function() _connectWebsocket;
  final Future<bool> Function() _syncRemote;
  final Future<void> Function() _hashAssets;
  final Future<void> Function() _syncLinkedAlbums;
  final Future<void> Function(String userId) _startBackup;
  final void Function() _stopBackup;
  final Future<void> Function() _cancelRemoteWork;
  final Future<void> Function() _cancelLocalWork;

  @override
  CancellableRequest<OfflineResult<OperationCompletion>> reconcile(ReconciliationRequest request) {
    final operation = _ServerReconciliationOperation(
      request: request,
      epochs: _epochs,
      snapshot: _readSnapshot(),
      disconnectWebsocket: _disconnectWebsocket,
      connectWebsocket: _connectWebsocket,
      syncRemote: _syncRemote,
      hashAssets: _hashAssets,
      syncLinkedAlbums: _syncLinkedAlbums,
      startBackup: _startBackup,
      stopBackup: _stopBackup,
      cancelRemoteWork: _cancelRemoteWork,
      cancelLocalWork: _cancelLocalWork,
    );
    operation.start();
    return operation;
  }
}

final class _ServerReconciliationOperation implements CancellableRequest<OfflineResult<OperationCompletion>> {
  _ServerReconciliationOperation({
    required this.request,
    required this.epochs,
    required this.snapshot,
    required this.disconnectWebsocket,
    required this.connectWebsocket,
    required this.syncRemote,
    required this.hashAssets,
    required this.syncLinkedAlbums,
    required this.startBackup,
    required this.stopBackup,
    required this.cancelRemoteWork,
    required this.cancelLocalWork,
  });

  final ReconciliationRequest request;
  final SessionEpochController epochs;
  final ReconciliationSnapshot snapshot;
  final void Function() disconnectWebsocket;
  final void Function() connectWebsocket;
  final Future<bool> Function() syncRemote;
  final Future<void> Function() hashAssets;
  final Future<void> Function() syncLinkedAlbums;
  final Future<void> Function(String userId) startBackup;
  final void Function() stopBackup;
  final Future<void> Function() cancelRemoteWork;
  final Future<void> Function() cancelLocalWork;
  final Completer<OfflineResult<OperationCompletion>> _completion = Completer();

  Future<void>? _work;
  Future<void>? _cancellation;
  bool _cancelled = false;

  @override
  Future<OfflineResult<OperationCompletion>> get result => _completion.future;

  void start() => _work = _run();

  Future<void> _run() async {
    try {
      _ensureCurrent();
      disconnectWebsocket();
      _ensureCurrent();
      connectWebsocket();
      _ensureCurrent();
      final syncSucceeded = await syncRemote();
      _ensureCurrent();
      if (!syncSucceeded) {
        _complete(const OfflineResult.failure(OfflineErrorCode.serverUnavailable));
        return;
      }

      await hashAssets();
      _ensureCurrent();

      if (snapshot.syncAlbums) {
        _ensureCurrent();
        await syncLinkedAlbums();
        _ensureCurrent();
      }

      final userId = snapshot.userId;
      if (snapshot.backupEnabled && userId != null && userId.isNotEmpty) {
        _ensureCurrent();
        await startBackup(userId);
        _ensureCurrent();
      }

      _complete(const OfflineResult.success(OperationCompletion.completed));
    } on _ReconciliationStopped {
      _complete(const OfflineResult.failure(OfflineErrorCode.cancelled));
    } on Object {
      _complete(const OfflineResult.failure(OfflineErrorCode.serverUnavailable));
    }
  }

  @override
  Future<void> cancel() => _cancellation ??= _cancel();

  Future<void> _cancel() async {
    _cancelled = true;
    Object? firstError;
    StackTrace? firstStackTrace;

    Future<void> attempt(FutureOr<void> Function() action) async {
      try {
        await action();
      } on Object catch (error, stackTrace) {
        firstError ??= error;
        firstStackTrace ??= stackTrace;
      }
    }

    await attempt(cancelRemoteWork);
    await attempt(cancelLocalWork);
    await attempt(stopBackup);
    await attempt(disconnectWebsocket);
    await attempt(() async => _work);
    _complete(const OfflineResult.failure(OfflineErrorCode.cancelled));

    if (firstError != null) {
      Error.throwWithStackTrace(firstError!, firstStackTrace!);
    }
  }

  void _ensureCurrent() {
    final identity = ReachabilityIdentity(sessionEpoch: request.sessionEpoch, probeGeneration: request.probeGeneration);
    if (_cancelled || !epochs.isCurrent(identity)) {
      throw const _ReconciliationStopped();
    }
  }

  void _complete(OfflineResult<OperationCompletion> result) {
    if (!_completion.isCompleted) {
      _completion.complete(result);
    }
  }
}

final class _ReconciliationStopped implements Exception {
  const _ReconciliationStopped();
}
