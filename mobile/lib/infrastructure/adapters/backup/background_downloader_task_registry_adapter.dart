import 'package:background_downloader/background_downloader.dart';

abstract interface class BackupTaskRegistryGateway {
  Future<void> get ready;

  Future<List<Task>> nativeTasks(String group);

  Future<List<Task>> nativeTasksInGroups(Set<String> groups);

  Future<List<TaskRecord>> trackingRecords(TaskStatus status, String group);

  Future<List<TaskRecord>> allTrackingRecords(String group);

  Future<bool> cancelNative(String group);

  Future<void> resetNative(String group);

  Future<void> deleteTrackingRecords(Iterable<String> taskIds);

  Future<void> repairTracking(TaskRecord record);
}

final class BackgroundDownloaderTaskRegistryAdapter implements BackupTaskRegistryGateway {
  BackgroundDownloaderTaskRegistryAdapter(this._downloader)
    : _ready = _downloader.trackTasks(markDownloadedComplete: false).then<void>((_) {});

  final FileDownloader _downloader;
  final Future<void> _ready;

  @override
  Future<void> get ready => _ready;

  @override
  Future<bool> cancelNative(String group) => _downloader.cancelAll(group: group);

  @override
  Future<List<Task>> nativeTasks(String group) {
    return _downloader.allTasks(group: group, includeTasksWaitingToRetry: true);
  }

  @override
  Future<List<Task>> nativeTasksInGroups(Set<String> groups) async {
    final tasks = await _downloader.allTasks(allGroups: true);
    return tasks.where((task) => groups.contains(task.group)).toList(growable: false);
  }

  @override
  Future<List<TaskRecord>> allTrackingRecords(String group) => _downloader.database.allRecords(group: group);

  @override
  Future<void> deleteTrackingRecords(Iterable<String> taskIds) => _downloader.database.deleteRecordsWithIds(taskIds);

  @override
  Future<void> repairTracking(TaskRecord record) {
    return _downloader.database.updateRecord(record);
  }

  @override
  Future<void> resetNative(String group) async {
    await _downloader.reset(group: group);
  }

  @override
  Future<List<TaskRecord>> trackingRecords(TaskStatus status, String group) {
    return _downloader.database.allRecordsWithStatus(status, group: group);
  }
}
