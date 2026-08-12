import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/background_task_runner.interface.dart';
import 'package:immich_mobile/domain/interfaces/cancellable_request.interface.dart';
import 'package:immich_mobile/domain/models/background_task.model.dart';
import 'package:immich_mobile/domain/utils/migrate_cloud_ids.dart' as m;
import 'package:immich_mobile/domain/utils/sync_linked_album.dart';
import 'package:immich_mobile/providers/infrastructure/sync.provider.dart';
import 'package:immich_mobile/providers/background_sync.provider.dart';
import 'package:immich_mobile/utils/isolate.dart';
import 'package:worker_manager/worker_manager.dart';

final class IsolateBackgroundTaskRunner implements BackgroundTaskRunner {
  const IsolateBackgroundTaskRunner();

  @override
  CancellableRequest<Object?> start({required BackgroundTaskDescriptor task, String? debugLabel}) {
    final worker = runInIsolateGentle<Object?, BackgroundTaskDescriptor>(
      computation: executeBackgroundTask,
      argument: task,
      debugLabel: debugLabel,
    );
    return _WorkerBackgroundTask(worker);
  }
}

Future<Object?> executeBackgroundTask(ProviderContainer ref, BackgroundTaskDescriptor task) async {
  final current = ref.read(backgroundTaskContextSourceProvider).capture();
  return executeBackgroundTaskWhenCurrent(
    task: task,
    currentContext: current,
    dispatch: () => _dispatchBackgroundTask(ref, task),
  );
}

Future<T> executeBackgroundTaskWhenCurrent<T>({
  required BackgroundTaskDescriptor task,
  required BackgroundTaskContextBinding? currentContext,
  required Future<T> Function() dispatch,
}) {
  if (task.requiresServerContext) {
    final binding = task.contextBinding;
    if (binding == null || binding != currentContext) {
      return Future<T>.error(const BackgroundTaskContextChanged());
    }
  }
  return dispatch();
}

Future<Object?> _dispatchBackgroundTask(ProviderContainer ref, BackgroundTaskDescriptor task) async {
  switch (task.kind) {
    case BackgroundTaskKind.localSync:
      await ref.read(localSyncServiceProvider).sync(full: task.full!);
      return null;
    case BackgroundTaskKind.hashAssets:
      await ref.read(hashServiceProvider).hashAssets();
      return null;
    case BackgroundTaskKind.remoteSync:
      return ref.read(syncStreamServiceProvider).sync();
    case BackgroundTaskKind.cloudIds:
      await m.syncCloudIds(ref);
      return null;
    case BackgroundTaskKind.linkedAlbums:
      await syncLinkedAlbumsIsolated(ref);
      return null;
    case BackgroundTaskKind.websocketBatch:
      await ref
          .read(syncStreamServiceProvider)
          .handleWsAssetUploadReadyV1Batch((task.payload! as List).cast<dynamic>());
      return null;
    case BackgroundTaskKind.websocketEdit:
      await ref.read(syncStreamServiceProvider).handleWsAssetEditReadyV1(task.payload);
      return null;
  }
}

final class _WorkerBackgroundTask implements CancellableRequest<Object?> {
  const _WorkerBackgroundTask(this._worker);

  final Cancelable<Object?> _worker;

  @override
  Future<Object?> get result => _worker.catchError((Object error, StackTrace stackTrace) {
    if (error is CanceledError) {
      Error.throwWithStackTrace(const BackgroundTaskCancelled(), stackTrace);
    }
    Error.throwWithStackTrace(error, stackTrace);
  });

  @override
  Future<void> cancel() async => _worker.cancel();
}
