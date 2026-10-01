import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/background_downloader_task_registry_adapter.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';
import 'package:mocktail/mocktail.dart';

class _Gateway extends Mock implements BackupTaskRegistryGateway {}

void main() {
  test('manual status is routed only to manual listeners and automatic status only to backup callback', () async {
    final repository = UploadRepository(taskRegistry: _Gateway());
    final manual = <TaskStatusUpdate>[];
    final automatic = <TaskStatusUpdate>[];
    repository.onUploadStatus = automatic.add;
    final subscription = repository.manualStatusUpdates.listen(manual.add);
    addTearDown(subscription.cancel);
    addTearDown(repository.dispose);
    final manualUpdate = _status(kManualUploadGroup);
    final automaticUpdate = _status(kBackupGroup);

    repository.dispatchStatusUpdate(manualUpdate);
    repository.dispatchStatusUpdate(automaticUpdate);
    await pumpEventQueue();

    expect(manual, [manualUpdate]);
    expect(automatic, [automaticUpdate]);
  });

  test('manual progress does not reach automatic progress consumer', () async {
    final repository = UploadRepository(taskRegistry: _Gateway());
    final manual = <TaskProgressUpdate>[];
    final automatic = <TaskProgressUpdate>[];
    repository.onTaskProgress = automatic.add;
    final subscription = repository.manualProgressUpdates.listen(manual.add);
    addTearDown(subscription.cancel);
    addTearDown(repository.dispose);
    final manualUpdate = _progress(kManualUploadGroup);
    final automaticUpdate = _progress(kBackupGroup);

    repository.dispatchProgressUpdate(manualUpdate);
    repository.dispatchProgressUpdate(automaticUpdate);
    await pumpEventQueue();

    expect(manual, [manualUpdate]);
    expect(automatic, [automaticUpdate]);
  });
}

TaskStatusUpdate _status(String group) => TaskStatusUpdate(
  UploadTask(taskId: '$group-task', url: 'https://photos.example/api/assets', filename: 'image.jpg', group: group),
  TaskStatus.complete,
);

TaskProgressUpdate _progress(String group) => TaskProgressUpdate(
  UploadTask(taskId: '$group-task', url: 'https://photos.example/api/assets', filename: 'image.jpg', group: group),
  0.5,
);
