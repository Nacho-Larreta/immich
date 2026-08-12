enum NativeBackupTaskStatus { active, canceling, unknown }

final class NativeBackupTask {
  const NativeBackupTask(this.taskId, {this.status = NativeBackupTaskStatus.active});

  final String taskId;
  final NativeBackupTaskStatus status;
}

abstract interface class BackupTaskDrainPort<Group> {
  Future<bool> cancelNative(Set<Group> groups);

  Future<void> resetNative(Set<Group> groups);

  Future<List<NativeBackupTask>> nativeSnapshot(Set<Group> groups);

  Future<bool> purgeTrackingAbsentFromNative(Set<Group> groups);
}
