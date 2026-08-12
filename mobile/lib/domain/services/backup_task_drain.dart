import 'package:immich_mobile/domain/interfaces/backup_task_drain.interface.dart';

final class BackupTaskDrain<Group> {
  const BackupTaskDrain(this._port, {this.stabilityInterval = const Duration(milliseconds: 20)});

  final BackupTaskDrainPort<Group> _port;
  final Duration stabilityInterval;

  Future<bool> cancelAndDrain(Set<Group> groups) async {
    try {
      if (!await _port.cancelNative(groups)) return false;
      await _port.resetNative(groups);
      if (!await _nativeIsEmpty(groups)) return false;
      await Future<void>.delayed(stabilityInterval);
      if (!await _nativeIsEmpty(groups)) return false;
      return _port.purgeTrackingAbsentFromNative(groups);
    } on Object {
      return false;
    }
  }

  Future<bool> _nativeIsEmpty(Set<Group> groups) async {
    final tasks = await _port.nativeSnapshot(groups);
    return tasks.isEmpty;
  }
}
