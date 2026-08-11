import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/utils/migrate_cloud_ids.dart' as m;
import 'package:immich_mobile/domain/utils/sync_linked_album.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/utils/isolate.dart';
import 'package:worker_manager/worker_manager.dart';

typedef SyncCallback = void Function();
typedef SyncCallbackWithResult<T> = void Function(T result);
typedef SyncErrorCallback = void Function(String error);
typedef SyncOperationTerminalCallback =
    void Function(int operationId, SyncOperationType operation, SyncTerminal terminal);

enum SyncOperationType { remote, local, hashing, cloudIds, websocket, linkedAlbums }

enum SyncTerminal { success, error, cancelled }

void consumeBackgroundSyncTap(Future<dynamic> operation) {
  unawaited(operation.then<void>((_) {}, onError: (Object _, StackTrace __) {}));
}

abstract interface class BackgroundTaskRunner {
  Cancelable<T?> start<T>({required Future<T> Function(ProviderContainer ref) computation, String? debugLabel});
}

final class IsolateBackgroundTaskRunner implements BackgroundTaskRunner {
  const IsolateBackgroundTaskRunner();

  @override
  Cancelable<T?> start<T>({required Future<T> Function(ProviderContainer ref) computation, String? debugLabel}) =>
      runInIsolateGentle(computation: computation, debugLabel: debugLabel);
}

class BackgroundSyncManager {
  final SyncCallback? onRemoteSyncStart;
  final SyncCallbackWithResult<bool?>? onRemoteSyncComplete;
  final SyncErrorCallback? onRemoteSyncError;

  final SyncCallback? onLocalSyncStart;
  final SyncCallback? onLocalSyncComplete;
  final SyncErrorCallback? onLocalSyncError;

  final SyncCallback? onHashingStart;
  final SyncCallback? onHashingComplete;
  final SyncErrorCallback? onHashingError;

  final SyncCallback? onCloudIdSyncStart;
  final SyncCallback? onCloudIdSyncComplete;
  final SyncErrorCallback? onCloudIdSyncError;
  final SyncCallback? onRemoteSyncCancelled;
  final SyncCallback? onLocalSyncCancelled;
  final SyncCallback? onHashingCancelled;
  final SyncCallback? onCloudIdSyncCancelled;
  final SyncOperationTerminalCallback? onTerminal;
  final BackgroundTaskRunner _taskRunner;

  _SyncOperation<bool>? _syncTask;
  _SyncOperation<void>? _syncWebsocketTask;
  _SyncOperation<void>? _cloudIdSyncTask;
  _SyncOperation<void>? _deviceAlbumSyncTask;
  _SyncOperation<void>? _linkedAlbumSyncTask;
  _SyncOperation<void>? _hashTask;
  var _nextOperationId = 0;

  BackgroundSyncManager({
    this.onRemoteSyncStart,
    this.onRemoteSyncComplete,
    this.onRemoteSyncError,
    this.onLocalSyncStart,
    this.onLocalSyncComplete,
    this.onLocalSyncError,
    this.onHashingStart,
    this.onHashingComplete,
    this.onHashingError,
    this.onCloudIdSyncStart,
    this.onCloudIdSyncComplete,
    this.onCloudIdSyncError,
    this.onRemoteSyncCancelled,
    this.onLocalSyncCancelled,
    this.onHashingCancelled,
    this.onCloudIdSyncCancelled,
    this.onTerminal,
    BackgroundTaskRunner taskRunner = const IsolateBackgroundTaskRunner(),
  }) : _taskRunner = taskRunner;

  Future<void> cancel() async {
    final futures = <Future>[];

    if (_syncTask != null) {
      futures.add(_syncTask!.completion);
    }
    _syncTask?.task.cancel();

    if (_syncWebsocketTask != null) {
      futures.add(_syncWebsocketTask!.completion);
    }
    _syncWebsocketTask?.task.cancel();

    if (_cloudIdSyncTask != null) {
      futures.add(_cloudIdSyncTask!.completion);
    }
    _cloudIdSyncTask?.task.cancel();

    if (_linkedAlbumSyncTask != null) {
      futures.add(_linkedAlbumSyncTask!.completion);
    }
    _linkedAlbumSyncTask?.task.cancel();

    try {
      await Future.wait(futures);
    } on CanceledError {
      // Cancellation is the requested terminal state.
    }
  }

  Future<void> cancelLocal() async {
    final futures = <Future>[];

    if (_hashTask != null) {
      futures.add(_hashTask!.completion);
    }
    _hashTask?.task.cancel();

    if (_deviceAlbumSyncTask != null) {
      futures.add(_deviceAlbumSyncTask!.completion);
    }
    _deviceAlbumSyncTask?.task.cancel();

    try {
      await Future.wait(futures);
    } on CanceledError {
      // Cancellation is the requested terminal state.
    }
  }

  // No need to cancel the task, as it can also be run when the user logs out
  Future<void> syncLocal({bool full = false}) {
    if (_deviceAlbumSyncTask != null) {
      return _deviceAlbumSyncTask!.completion;
    }

    final operationId = ++_nextOperationId;
    try {
      onLocalSyncStart?.call();
      late final _SyncOperation<void> operation;
      final task = _taskRunner.start<void>(
        computation: (ref) => ref.read(localSyncServiceProvider).sync(full: full),
        debugLabel: 'local-sync-full-$full',
      );
      operation = _SyncOperation(operationId, task);
      _deviceAlbumSyncTask = operation;
      operation.completion = task
          .then<void>(
            (_) => _complete(operation, SyncOperationType.local, SyncTerminal.success, onLocalSyncComplete),
            onError: (Object error, StackTrace stackTrace) {
              _fail(operation, SyncOperationType.local, error, onLocalSyncError, onLocalSyncCancelled);
              Error.throwWithStackTrace(error, stackTrace);
            },
          )
          .whenComplete(() {
            if (identical(_deviceAlbumSyncTask, operation)) _deviceAlbumSyncTask = null;
          });
      return operation.completion;
    } on Object catch (error, stackTrace) {
      _emitStartFailure(operationId, SyncOperationType.local, error, onLocalSyncError);
      return Future<void>.error(error, stackTrace);
    }
  }

  Future<void> hashAssets() {
    if (_hashTask != null) {
      return _hashTask!.completion;
    }

    final operationId = ++_nextOperationId;
    try {
      onHashingStart?.call();
      late final _SyncOperation<void> operation;
      final task = _taskRunner.start<void>(
        computation: (ref) => ref.read(hashServiceProvider).hashAssets(),
        debugLabel: 'hash-assets',
      );
      operation = _SyncOperation(operationId, task);
      _hashTask = operation;
      operation.completion = task
          .then<void>(
            (_) => _complete(operation, SyncOperationType.hashing, SyncTerminal.success, onHashingComplete),
            onError: (Object error, StackTrace stackTrace) {
              _fail(operation, SyncOperationType.hashing, error, onHashingError, onHashingCancelled);
              Error.throwWithStackTrace(error, stackTrace);
            },
          )
          .whenComplete(() {
            if (identical(_hashTask, operation)) _hashTask = null;
          });
      return operation.completion;
    } on Object catch (error, stackTrace) {
      _emitStartFailure(operationId, SyncOperationType.hashing, error, onHashingError);
      return Future<void>.error(error, stackTrace);
    }
  }

  Future<bool> syncRemote() {
    if (_syncTask != null) {
      return _syncTask!.completion;
    }

    final operationId = ++_nextOperationId;
    try {
      onRemoteSyncStart?.call();
      late final _SyncOperation<bool> operation;
      final task = _taskRunner.start<bool>(
        computation: (ref) => ref.read(syncStreamServiceProvider).sync(),
        debugLabel: 'remote-sync',
      );
      operation = _SyncOperation(operationId, task);
      _syncTask = operation;
      operation.completion = task
          .then<bool>(
            (result) {
              final success = result ?? false;
              _complete(
                operation,
                SyncOperationType.remote,
                SyncTerminal.success,
                () => onRemoteSyncComplete?.call(success),
              );
              return success;
            },
            onError: (Object error, StackTrace _) {
              _fail(operation, SyncOperationType.remote, error, onRemoteSyncError, onRemoteSyncCancelled);
              return false;
            },
          )
          .whenComplete(() {
            if (identical(_syncTask, operation)) _syncTask = null;
          });
      return operation.completion;
    } on Object catch (error, _) {
      _emitStartFailure(operationId, SyncOperationType.remote, error, onRemoteSyncError);
      return Future<bool>.value(false);
    }
  }

  Future<void> syncWebsocketBatch(List<dynamic> batchData) {
    if (_syncWebsocketTask != null) {
      return _syncWebsocketTask!.completion;
    }
    return _startWebsocketOperation(
      computation: (ref) => ref.read(syncStreamServiceProvider).handleWsAssetUploadReadyV1Batch(batchData),
      debugLabel: 'websocket-batch',
    );
  }

  Future<void> syncWebsocketEdit(dynamic data) {
    if (_syncWebsocketTask != null) {
      return _syncWebsocketTask!.completion;
    }
    return _startWebsocketOperation(
      computation: (ref) => ref.read(syncStreamServiceProvider).handleWsAssetEditReadyV1(data),
      debugLabel: 'websocket-edit',
    );
  }

  Future<void> syncLinkedAlbum() {
    if (_linkedAlbumSyncTask != null) {
      return _linkedAlbumSyncTask!.completion;
    }

    final operationId = ++_nextOperationId;
    try {
      late final _SyncOperation<void> operation;
      final task = _taskRunner.start<void>(computation: syncLinkedAlbumsIsolated, debugLabel: 'linked-album-sync');
      operation = _SyncOperation(operationId, task);
      _linkedAlbumSyncTask = operation;
      operation.completion = task
          .then<void>(
            (_) => _complete(operation, SyncOperationType.linkedAlbums, SyncTerminal.success, null),
            onError: (Object error, StackTrace stackTrace) {
              _fail(operation, SyncOperationType.linkedAlbums, error, null, null);
              Error.throwWithStackTrace(error, stackTrace);
            },
          )
          .whenComplete(() {
            if (identical(_linkedAlbumSyncTask, operation)) _linkedAlbumSyncTask = null;
          });
      return operation.completion;
    } on Object catch (error, stackTrace) {
      _emitStartFailure(operationId, SyncOperationType.linkedAlbums, error, null);
      return Future<void>.error(error, stackTrace);
    }
  }

  Future<void> _startWebsocketOperation({
    required Future<void> Function(ProviderContainer ref) computation,
    required String debugLabel,
  }) {
    final operationId = ++_nextOperationId;
    try {
      late final _SyncOperation<void> operation;
      final task = _taskRunner.start<void>(computation: computation, debugLabel: debugLabel);
      operation = _SyncOperation(operationId, task);
      _syncWebsocketTask = operation;
      operation.completion = task
          .then<void>(
            (_) => _complete(operation, SyncOperationType.websocket, SyncTerminal.success, null),
            onError: (Object error, StackTrace stackTrace) {
              _fail(operation, SyncOperationType.websocket, error, null, null);
              Error.throwWithStackTrace(error, stackTrace);
            },
          )
          .whenComplete(() {
            if (identical(_syncWebsocketTask, operation)) _syncWebsocketTask = null;
          });
      return operation.completion;
    } on Object catch (error, stackTrace) {
      _emitStartFailure(operationId, SyncOperationType.websocket, error, null);
      return Future<void>.error(error, stackTrace);
    }
  }

  Future<void> syncCloudIds() {
    if (_cloudIdSyncTask != null) {
      return _cloudIdSyncTask!.completion;
    }

    final operationId = ++_nextOperationId;
    try {
      onCloudIdSyncStart?.call();
      late final _SyncOperation<void> operation;
      final task = _taskRunner.start<void>(computation: m.syncCloudIds);
      operation = _SyncOperation(operationId, task);
      _cloudIdSyncTask = operation;
      operation.completion = task
          .then<void>(
            (_) => _complete(operation, SyncOperationType.cloudIds, SyncTerminal.success, onCloudIdSyncComplete),
            onError: (Object error, StackTrace stackTrace) {
              _fail(operation, SyncOperationType.cloudIds, error, onCloudIdSyncError, onCloudIdSyncCancelled);
              Error.throwWithStackTrace(error, stackTrace);
            },
          )
          .whenComplete(() {
            if (identical(_cloudIdSyncTask, operation)) _cloudIdSyncTask = null;
          });
      return operation.completion;
    } on Object catch (error, stackTrace) {
      _emitStartFailure(operationId, SyncOperationType.cloudIds, error, onCloudIdSyncError);
      return Future<void>.error(error, stackTrace);
    }
  }

  void _complete<T>(
    _SyncOperation<T> operation,
    SyncOperationType type,
    SyncTerminal terminal,
    SyncCallback? callback,
  ) {
    if (!operation.markTerminal()) return;
    try {
      callback?.call();
    } finally {
      onTerminal?.call(operation.id, type, terminal);
    }
  }

  void _fail<T>(
    _SyncOperation<T> operation,
    SyncOperationType type,
    Object error,
    SyncErrorCallback? errorCallback,
    SyncCallback? cancelledCallback,
  ) {
    final cancelled = error is CanceledError;
    if (operation.markTerminal()) {
      try {
        if (cancelled) {
          cancelledCallback?.call();
        } else {
          errorCallback?.call(error.toString());
        }
      } finally {
        onTerminal?.call(operation.id, type, cancelled ? SyncTerminal.cancelled : SyncTerminal.error);
      }
    }
  }

  void _emitStartFailure(int operationId, SyncOperationType type, Object error, SyncErrorCallback? callback) {
    try {
      callback?.call(error.toString());
    } finally {
      onTerminal?.call(operationId, type, SyncTerminal.error);
    }
  }
}

final class _SyncOperation<T> {
  _SyncOperation(this.id, this.task);

  final int id;
  final Cancelable<T?> task;
  late final Future<T> completion;
  var _terminal = false;

  bool markTerminal() {
    if (_terminal) return false;
    _terminal = true;
    return true;
  }
}
