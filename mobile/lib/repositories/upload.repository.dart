import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:background_downloader/background_downloader.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_task_drain.interface.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/services/backup_task_drain.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/background_downloader_task_registry_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:logging/logging.dart';
import 'package:http/http.dart';
import 'package:immich_mobile/utils/debug_print.dart';

final uploadRepositoryProvider = Provider((ref) => UploadRepository());

class UploadRepository implements BackupTaskRegistryPort, BackupTaskDrainPort<BackupTaskGroup> {
  final Logger logger = Logger('UploadRepository');
  void Function(TaskStatusUpdate)? onUploadStatus;
  void Function(TaskProgressUpdate)? onTaskProgress;

  late final BackupTaskRegistryGateway _taskRegistry;

  UploadRepository({BackupTaskRegistryGateway? taskRegistry}) {
    if (taskRegistry == null) {
      final downloader = FileDownloader();
      downloader.registerCallbacks(
        group: kBackupGroup,
        taskStatusCallback: (update) => onUploadStatus?.call(update),
        taskProgressCallback: (update) => onTaskProgress?.call(update),
      );
      downloader.registerCallbacks(
        group: kBackupLivePhotoGroup,
        taskStatusCallback: (update) => onUploadStatus?.call(update),
        taskProgressCallback: (update) => onTaskProgress?.call(update),
      );
      downloader.registerCallbacks(
        group: kManualUploadGroup,
        taskStatusCallback: (update) => onUploadStatus?.call(update),
        taskProgressCallback: (update) => onTaskProgress?.call(update),
      );
      _taskRegistry = BackgroundDownloaderTaskRegistryAdapter(downloader);
    } else {
      _taskRegistry = taskRegistry;
    }
  }

  @override
  Future<void> get ready => _taskRegistry.ready;

  @override
  Future<List<BackupTaskSnapshot>> snapshot(Set<BackupTaskGroup> groups) async {
    await ready;
    final snapshots = <(BackupTaskGroup, String), BackupTaskSnapshot>{};
    for (final group in groups) {
      final groupName = _groupName(group);
      final nativeTasks = await _taskRegistry.nativeTasks(groupName);
      for (final task in nativeTasks) {
        snapshots[(group, task.taskId)] = _snapshot(task, BackupTaskStatus.running, group);
      }
      for (final status in const [
        TaskStatus.enqueued,
        TaskStatus.running,
        TaskStatus.waitingToRetry,
        TaskStatus.paused,
      ]) {
        final records = await _taskRegistry.trackingRecords(status, groupName);
        for (final record in records) {
          final key = (group, record.task.taskId);
          final native = snapshots[key];
          if (native != null) {
            snapshots[key] = BackupTaskSnapshot(
              taskId: native.taskId,
              group: native.group,
              status: native.status,
              metadata: BackupTaskMetadata.tryParse(record.task.metaData),
            );
          }
        }
      }
    }
    return snapshots.values.toList(growable: false);
  }

  @override
  Future<bool> cancelAndDrain(Set<BackupTaskGroup> groups) => BackupTaskDrain(this).cancelAndDrain(groups);

  @override
  Future<bool> cancelNative(Set<BackupTaskGroup> groups) async {
    await ready;
    var acknowledged = true;
    for (final group in groups) {
      acknowledged = await _taskRegistry.cancelNative(_groupName(group)) && acknowledged;
    }
    return acknowledged;
  }

  @override
  Future<void> resetNative(Set<BackupTaskGroup> groups) async {
    for (final group in groups) {
      await _taskRegistry.resetNative(_groupName(group));
    }
  }

  @override
  Future<List<NativeBackupTask>> nativeSnapshot(Set<BackupTaskGroup> groups) async {
    final tasks = <NativeBackupTask>[];
    for (final group in groups) {
      final nativeTasks = await _taskRegistry.nativeTasks(_groupName(group));
      tasks.addAll(nativeTasks.map((task) => NativeBackupTask(task.taskId)));
    }
    return tasks;
  }

  @override
  Future<bool> purgeTrackingAbsentFromNative(Set<BackupTaskGroup> groups) async {
    final groupNames = groups.map(_groupName).toSet();
    final records = <TaskRecord>[];
    for (final groupName in groupNames) {
      records.addAll(await _taskRegistry.allTrackingRecords(groupName));
    }
    if ((await _taskRegistry.nativeTasksInGroups(groupNames)).isNotEmpty) return false;

    try {
      for (final groupName in groupNames) {
        final groupRecords = records.where((record) => record.task.group == groupName);
        await _taskRegistry.deleteTrackingRecords(groupRecords.map((record) => record.taskId));
      }
      final nativeAfterPurge = await _taskRegistry.nativeTasksInGroups(groupNames);
      if (nativeAfterPurge.isEmpty) return true;
      await _repairTracking(nativeAfterPurge, records);
      return false;
    } on Object {
      await _restoreTracking(records);
      return false;
    }
  }

  Future<void> _repairTracking(List<Task> nativeTasks, List<TaskRecord> capturedRecords) async {
    final capturedById = {for (final record in capturedRecords) record.taskId: record};
    for (final task in nativeTasks) {
      await _taskRegistry.repairTracking(capturedById[task.taskId] ?? TaskRecord(task, TaskStatus.running, 0, -1));
    }
  }

  Future<void> _restoreTracking(List<TaskRecord> records) async {
    for (final record in records) {
      await _taskRegistry.repairTracking(record);
    }
  }

  Future<Task?> completedTask(BackupTaskClaim claim) async {
    await ready;
    final group = _groupName(claim.group);
    final records = await FileDownloader().database.allRecordsWithStatus(TaskStatus.complete, group: group);
    for (final record in records) {
      if (record.task.taskId == claim.taskId && record.task.group == group) return record.task;
    }
    return null;
  }

  BackupTaskSnapshot _snapshot(Task task, BackupTaskStatus status, BackupTaskGroup group) => BackupTaskSnapshot(
    taskId: task.taskId,
    group: group,
    status: status,
    metadata: BackupTaskMetadata.tryParse(task.metaData),
  );

  static String _groupName(BackupTaskGroup group) => switch (group) {
    BackupTaskGroup.primary => kBackupGroup,
    BackupTaskGroup.livePhoto => kBackupLivePhotoGroup,
  };

  Future<void> enqueueBackground(UploadTask task) {
    return FileDownloader().enqueue(task);
  }

  Future<List<bool>> enqueueBackgroundAll(List<UploadTask> tasks) {
    return FileDownloader().enqueueAll(tasks);
  }

  Future<void> deleteDatabaseRecords(String group) {
    return FileDownloader().database.deleteAllRecords(group: group);
  }

  Future<bool> cancelAll(String group) {
    return FileDownloader().cancelAll(group: group);
  }

  Future<int> reset(String group) {
    return FileDownloader().reset(group: group);
  }

  /// Get a list of tasks that are ENQUEUED or RUNNING
  Future<List<Task>> getActiveTasks(String group) {
    return FileDownloader().allTasks(group: group);
  }

  Future<void> start() {
    return FileDownloader().start();
  }

  Future<void> getUploadInfo() async {
    final [enqueuedTasks, runningTasks, canceledTasks, waitingTasks, pausedTasks] = await Future.wait([
      FileDownloader().database.allRecordsWithStatus(TaskStatus.enqueued, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.running, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.canceled, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.waitingToRetry, group: kBackupGroup),
      FileDownloader().database.allRecordsWithStatus(TaskStatus.paused, group: kBackupGroup),
    ]);

    dPrint(
      () =>
          """
      Upload Info:
      Enqueued: ${enqueuedTasks.length}
      Running: ${runningTasks.length}
      Canceled: ${canceledTasks.length}
      Waiting: ${waitingTasks.length}
      Paused: ${pausedTasks.length}
    """,
    );
  }

  Future<UploadResult> uploadFile({
    required File file,
    required String originalFileName,
    required Map<String, String> fields,
    required Completer<void>? cancelToken,
    void Function(int bytes, int totalBytes)? onProgress,
    required String logContext,
    Uri? apiEndpoint,
    bool Function()? isContextCurrent,
  }) async {
    if (isContextCurrent?.call() == false) return UploadResult.staleContext();
    final String savedEndpoint = apiEndpoint?.toString() ?? Store.get(StoreKey.serverEndpoint);
    final baseRequest = ProgressMultipartRequest(
      'POST',
      Uri.parse('$savedEndpoint/assets'),
      abortTrigger: cancelToken?.future,
      onProgress: onProgress,
    );

    try {
      final fileStream = file.openRead();
      final assetRawUploadData = MultipartFile("assetData", fileStream, file.lengthSync(), filename: originalFileName);

      baseRequest.fields.addAll(fields);
      baseRequest.files.add(assetRawUploadData);

      if (isContextCurrent?.call() == false) return UploadResult.staleContext();
      final response = await NetworkRepository.client.send(baseRequest);
      final responseBodyString = await response.stream.bytesToString();
      if (isContextCurrent?.call() == false) return UploadResult.staleContext();

      if (![200, 201].contains(response.statusCode)) {
        String? errorMessage;

        if (response.statusCode == 413) {
          errorMessage = 'Error(413) File is too large to upload';
          return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
        }

        try {
          final error = jsonDecode(responseBodyString);
          errorMessage = error['message'] ?? error['error'];
        } catch (_) {
          errorMessage = responseBodyString.isNotEmpty
              ? responseBodyString
              : 'Upload failed with status ${response.statusCode}';
        }

        return UploadResult.error(statusCode: response.statusCode, errorMessage: errorMessage);
      }

      try {
        final responseBody = jsonDecode(responseBodyString);
        if (isContextCurrent?.call() == false) return UploadResult.staleContext();
        return UploadResult.success(remoteAssetId: responseBody['id'] as String);
      } catch (e) {
        return UploadResult.error(errorMessage: 'Failed to parse server response');
      }
    } on RequestAbortedException {
      logger.warning('foreground_upload_cancelled');
      return UploadResult.cancelled();
    } on Object {
      logger.warning('foreground_upload_failed');
      return UploadResult.error(errorMessage: 'Upload failed');
    }
  }
}

class ProgressMultipartRequest extends MultipartRequest with Abortable {
  ProgressMultipartRequest(super.method, super.url, {this.abortTrigger, this.onProgress});

  @override
  final Future<void>? abortTrigger;

  final void Function(int bytes, int totalBytes)? onProgress;

  @override
  ByteStream finalize() {
    final byteStream = super.finalize();
    if (onProgress == null) return byteStream;

    final total = contentLength;
    var bytes = 0;
    final stream = byteStream.transform(
      StreamTransformer.fromHandlers(
        handleData: (List<int> data, EventSink<List<int>> sink) {
          bytes += data.length;
          onProgress!(bytes, total);
          sink.add(data);
        },
      ),
    );
    return ByteStream(stream);
  }
}

class UploadResult {
  final bool isSuccess;
  final bool isCancelled;
  final String? remoteAssetId;
  final String? errorMessage;
  final int? statusCode;
  final bool isStaleContext;

  const UploadResult({
    required this.isSuccess,
    required this.isCancelled,
    this.remoteAssetId,
    this.errorMessage,
    this.statusCode,
    this.isStaleContext = false,
  });

  factory UploadResult.success({required String remoteAssetId}) {
    return UploadResult(isSuccess: true, isCancelled: false, remoteAssetId: remoteAssetId);
  }

  factory UploadResult.error({String? errorMessage, int? statusCode}) {
    return UploadResult(isSuccess: false, isCancelled: false, errorMessage: errorMessage, statusCode: statusCode);
  }

  factory UploadResult.cancelled() {
    return const UploadResult(isSuccess: false, isCancelled: true);
  }

  factory UploadResult.staleContext() {
    return const UploadResult(isSuccess: false, isCancelled: false, isStaleContext: true);
  }
}
