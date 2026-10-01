import 'package:background_downloader/background_downloader.dart';
import 'package:immich_mobile/constants/constants.dart';

abstract interface class ManualNativeTaskGateway {
  Future<bool> enqueue(UploadTask task);
  Future<List<Task>> nativeTasks();
  Future<TaskRecord?> recordForId(String taskId);
  Future<bool> cancel(String taskId);
}

final class DownloaderManualNativeTaskGateway implements ManualNativeTaskGateway {
  DownloaderManualNativeTaskGateway([FileDownloader? downloader]) : _downloader = downloader ?? FileDownloader();

  final FileDownloader _downloader;

  @override
  Future<bool> enqueue(UploadTask task) => _downloader.enqueue(task);

  @override
  Future<List<Task>> nativeTasks() => _downloader.allTasks(group: kManualUploadGroup, includeTasksWaitingToRetry: true);

  @override
  Future<TaskRecord?> recordForId(String taskId) => _downloader.database.recordForId(taskId);

  @override
  Future<bool> cancel(String taskId) => _downloader.cancelTaskWithId(taskId);
}
