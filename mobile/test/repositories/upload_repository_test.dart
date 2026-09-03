import 'package:background_downloader/background_downloader.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/constants/constants.dart';
import 'package:immich_mobile/domain/models/backup_execution_lease.model.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/background_downloader_task_registry_adapter.dart';
import 'package:immich_mobile/repositories/upload.repository.dart';

void main() {
  test('native empty plus residual tracking purges both groups and succeeds', () async {
    final gateway = _Gateway(
      nativeSnapshots: const [],
      records: {
        kBackupGroup: [_record('residual-primary', kBackupGroup)],
        kBackupLivePhotoGroup: [_record('residual-live', kBackupLivePhotoGroup)],
      },
    );
    final repository = UploadRepository(taskRegistry: gateway);

    expect(await repository.snapshot(BackupExecutionArbiter.groups), isEmpty);
    expect(await repository.cancelAndDrain(BackupExecutionArbiter.groups), isTrue);
    expect(gateway.purgedGroups, {kBackupGroup, kBackupLivePhotoGroup});
  });

  test('native task appearing between stable snapshots preserves tracking and fails closed', () async {
    final gateway = _Gateway(
      nativeSnapshots: [
        const [],
        const [],
        [_task('appeared', kBackupGroup)],
        const [],
      ],
      records: {
        kBackupGroup: [_record('residual-primary', kBackupGroup)],
      },
    );
    final repository = UploadRepository(taskRegistry: gateway);

    expect(await repository.cancelAndDrain(BackupExecutionArbiter.groups), isFalse);
    expect(gateway.purgedGroups, isEmpty);
    expect(gateway.records[kBackupGroup], isNotEmpty);
  });

  test('native task appearing after Q2 is retained in tracking and drain fails closed', () async {
    final appeared = _task('appeared-after-q2', kBackupGroup);
    final gateway = _Gateway(
      nativeSnapshots: [
        const [],
        const [],
        const [],
        const [],
        const [],
        [appeared],
      ],
      records: {
        kBackupGroup: [_record(appeared.taskId, kBackupGroup)],
      },
    );
    final repository = UploadRepository(taskRegistry: gateway);

    expect(await repository.cancelAndDrain(BackupExecutionArbiter.groups), isFalse);
    expect(gateway.records[kBackupGroup]?.map((record) => record.taskId), contains(appeared.taskId));
  });

  test('primary appearing while live-photo tracking is purged is repaired and fails closed', () async {
    final appeared = _task('primary-cross-group-race', kBackupGroup);
    final gateway = _Gateway(
      nativeSnapshots: List.filled(8, const []),
      records: {
        kBackupGroup: [_record(appeared.taskId, kBackupGroup)],
        kBackupLivePhotoGroup: [_record('residual-live', kBackupLivePhotoGroup)],
      },
      appearWhenDeletingGroup: kBackupLivePhotoGroup,
      taskToAppear: appeared,
    );
    final repository = UploadRepository(taskRegistry: gateway);

    expect(await repository.cancelAndDrain(BackupExecutionArbiter.groups), isFalse);
    expect(gateway.records[kBackupGroup]?.map((record) => record.taskId), contains(appeared.taskId));
  });

  test('live-photo appearing while primary tracking is purged is repaired and fails closed', () async {
    final appeared = _task('live-cross-group-race', kBackupLivePhotoGroup);
    final gateway = _Gateway(
      nativeSnapshots: List.filled(8, const []),
      records: {
        kBackupGroup: [_record('residual-primary', kBackupGroup)],
        kBackupLivePhotoGroup: [_record(appeared.taskId, kBackupLivePhotoGroup)],
      },
      appearWhenDeletingGroup: kBackupGroup,
      taskToAppear: appeared,
    );
    final repository = UploadRepository(taskRegistry: gateway);

    expect(await repository.cancelAndDrain({BackupTaskGroup.livePhoto, BackupTaskGroup.primary}), isFalse);
    expect(gateway.records[kBackupLivePhotoGroup]?.map((record) => record.taskId), contains(appeared.taskId));
  });

  test('cancel acknowledgement and reset errors fail closed without purging tracking', () async {
    final rejectedCancel = _Gateway(nativeSnapshots: const [], cancelAcknowledged: false);
    expect(await UploadRepository(taskRegistry: rejectedCancel).cancelAndDrain(BackupExecutionArbiter.groups), isFalse);
    expect(rejectedCancel.purgedGroups, isEmpty);

    final resetError = _Gateway(nativeSnapshots: const [], resetError: StateError('reset'));
    expect(await UploadRepository(taskRegistry: resetError).cancelAndDrain(BackupExecutionArbiter.groups), isFalse);
    expect(resetError.purgedGroups, isEmpty);
  });
}

UploadTask _task(String id, String group) =>
    UploadTask(taskId: id, url: 'https://photos.example/assets', filename: '$id.jpg', group: group);

TaskRecord _record(String id, String group) => TaskRecord(_task(id, group), TaskStatus.running, 0, 1);

final class _Gateway implements BackupTaskRegistryGateway {
  _Gateway({
    required List<List<Task>> nativeSnapshots,
    Map<String, List<TaskRecord>> records = const {},
    this.cancelAcknowledged = true,
    this.resetError,
    this.appearWhenDeletingGroup,
    this.taskToAppear,
  }) : nativeSnapshots = List.of(nativeSnapshots),
       records = records.map((group, records) => MapEntry(group, List.of(records)));

  final List<List<Task>> nativeSnapshots;
  final Map<String, List<TaskRecord>> records;
  final bool cancelAcknowledged;
  final Object? resetError;
  final String? appearWhenDeletingGroup;
  final Task? taskToAppear;
  final Set<String> purgedGroups = {};
  final List<Task> appearedTasks = [];

  @override
  Future<void> get ready async {}

  @override
  Future<bool> cancelNative(String group) async => cancelAcknowledged;

  @override
  Future<List<Task>> nativeTasks(String group) async {
    final scripted = nativeSnapshots.isEmpty ? const <Task>[] : nativeSnapshots.removeAt(0);
    return [...scripted, ...appearedTasks.where((task) => task.group == group)];
  }

  @override
  Future<List<Task>> nativeTasksInGroups(Set<String> groups) async {
    final scripted = nativeSnapshots.isEmpty ? const <Task>[] : nativeSnapshots.removeAt(0);
    return [...scripted, ...appearedTasks].where((task) => groups.contains(task.group)).toList();
  }

  @override
  Future<List<TaskRecord>> allTrackingRecords(String group) async => records[group] ?? const [];

  @override
  Future<void> deleteTrackingRecords(Iterable<String> taskIds) async {
    for (final entry in records.entries) {
      final before = entry.value.length;
      entry.value.removeWhere((record) => taskIds.contains(record.taskId));
      if (entry.value.length != before) {
        purgedGroups.add(entry.key);
        final task = taskToAppear;
        if (entry.key == appearWhenDeletingGroup && task != null) appearedTasks.add(task);
      }
    }
  }

  @override
  Future<void> repairTracking(TaskRecord record) async {
    final groupRecords = records.putIfAbsent(record.task.group, () => []);
    final existing = groupRecords.indexWhere((candidate) => candidate.taskId == record.taskId);
    if (existing == -1) {
      groupRecords.add(record);
    } else {
      groupRecords[existing] = record;
    }
  }

  @override
  Future<void> replayUndeliveredUpdates() async {}

  @override
  Future<void> resetNative(String group) async {
    if (resetError case final error?) throw error;
  }

  @override
  Future<List<TaskRecord>> trackingRecords(TaskStatus status, String group) async {
    return records[group]?.where((record) => record.status == status).toList() ?? const [];
  }
}
