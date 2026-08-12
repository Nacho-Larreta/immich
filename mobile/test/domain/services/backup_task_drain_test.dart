import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_task_drain.interface.dart';
import 'package:immich_mobile/domain/services/backup_task_drain.dart';

void main() {
  const groups = {'primary', 'live-photo'};

  test('purges residual tracking only after two native-empty snapshots', () async {
    final port = _DrainPort(nativeSnapshots: [const [], const [], const []], trackingTasks: {'residual'});
    final drain = BackupTaskDrain(port, stabilityInterval: Duration.zero);

    expect(await drain.cancelAndDrain(groups), isTrue);
    expect(port.events, ['cancel', 'reset', 'native', 'native', 'purge-safe']);
    expect(port.trackingTasks, isEmpty);
  });

  test('task appearing between native snapshots fails closed and preserves tracking', () async {
    final port = _DrainPort(
      nativeSnapshots: [
        const [],
        const [NativeBackupTask('appeared')],
      ],
      trackingTasks: {'residual'},
    );
    final drain = BackupTaskDrain(port, stabilityInterval: Duration.zero);

    expect(await drain.cancelAndDrain(groups), isFalse);
    expect(port.trackingTasks, {'residual'});
    expect(port.events, ['cancel', 'reset', 'native', 'native']);
  });

  test('cancel acknowledgement failure fails closed before reset', () async {
    final port = _DrainPort(nativeSnapshots: const [], cancelAcknowledged: false, trackingTasks: {'residual'});

    expect(await BackupTaskDrain(port).cancelAndDrain(groups), isFalse);
    expect(port.events, ['cancel']);
    expect(port.trackingTasks, {'residual'});
  });

  test('reset error fails closed and preserves tracking', () async {
    final port = _DrainPort(nativeSnapshots: const [], resetError: StateError('reset'), trackingTasks: {'residual'});

    expect(await BackupTaskDrain(port).cancelAndDrain(groups), isFalse);
    expect(port.events, ['cancel', 'reset']);
    expect(port.trackingTasks, {'residual'});
  });

  test('native active or canceling task is not treated as drained', () async {
    for (final status in [NativeBackupTaskStatus.active, NativeBackupTaskStatus.canceling]) {
      final port = _DrainPort(
        nativeSnapshots: [
          [NativeBackupTask('opaque', status: status)],
        ],
        trackingTasks: {'residual'},
      );

      expect(await BackupTaskDrain(port).cancelAndDrain(groups), isFalse);
      expect(port.trackingTasks, {'residual'});
    }
  });
}

final class _DrainPort implements BackupTaskDrainPort<String> {
  _DrainPort({
    required List<List<NativeBackupTask>> nativeSnapshots,
    this.cancelAcknowledged = true,
    this.resetError,
    Set<String> trackingTasks = const {},
  }) : _nativeSnapshots = List.of(nativeSnapshots),
       trackingTasks = Set.of(trackingTasks);

  final List<List<NativeBackupTask>> _nativeSnapshots;
  final bool cancelAcknowledged;
  final Object? resetError;
  final List<String> events = [];
  final Set<String> trackingTasks;

  @override
  Future<bool> cancelNative(Set<String> groups) async {
    events.add('cancel');
    return cancelAcknowledged;
  }

  @override
  Future<List<NativeBackupTask>> nativeSnapshot(Set<String> groups) async {
    events.add('native');
    return _nativeSnapshots.removeAt(0);
  }

  @override
  Future<bool> purgeTrackingAbsentFromNative(Set<String> groups) async {
    events.add('purge-safe');
    trackingTasks.clear();
    return true;
  }

  @override
  Future<void> resetNative(Set<String> groups) async {
    events.add('reset');
    if (resetError case final error?) throw error;
  }
}
