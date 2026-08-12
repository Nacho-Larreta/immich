import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/services/eager_backup_workload_subscription.dart';

void main() {
  test('A to null to B keeps exactly the newest subscription while A cancellation is pending', () async {
    final monitor = _ControlledWorkloads();
    final received = <BackupWorkload>[];
    final owner = EagerBackupWorkloadSubscription(
      workloads: monitor,
      diagnostics: const NoOpEagerBackupDiagnostics(),
      onWorkload: received.add,
    );
    addTearDown(() async {
      await owner.dispose();
      await monitor.dispose();
    });

    await owner.replace('A');
    monitor.blockCancellation('A');
    final removeA = owner.replace(null);
    await monitor.cancellationStarted('A');
    final subscribeB = owner.replace('B');
    await subscribeB;

    expect(monitor.liveUsers, {'B'});
    monitor.emit('A', const BackupWorkload(total: 1, remainder: 1, processing: 0));
    monitor.emit('B', const BackupWorkload(total: 2, remainder: 2, processing: 0));
    expect(received, hasLength(1));
    expect(received.single.remainder, 2);

    monitor.releaseCancellation('A');
    await removeA;
    expect(monitor.liveUsers, {'B'});
  });

  test('dispose during replacement prevents a new subscription and all later emissions', () async {
    final monitor = _ControlledWorkloads();
    final received = <BackupWorkload>[];
    final owner = EagerBackupWorkloadSubscription(
      workloads: monitor,
      diagnostics: const NoOpEagerBackupDiagnostics(),
      onWorkload: received.add,
    );
    addTearDown(monitor.dispose);

    await owner.replace('A');
    monitor.blockCancellation('A');
    final replace = owner.replace('B');
    await monitor.cancellationStarted('A');
    final dispose = owner.dispose();
    monitor.releaseCancellation('A');
    await Future.wait([replace, dispose]);

    expect(monitor.liveUsers, isEmpty);
    monitor.emit('A', const BackupWorkload(total: 1, remainder: 1, processing: 0));
    monitor.emit('B', const BackupWorkload(total: 1, remainder: 1, processing: 0));
    expect(received, isEmpty);
  });

  test('subscription made stale during listen is cancelled immediately', () async {
    final monitor = _ControlledWorkloads();
    late final EagerBackupWorkloadSubscription owner;
    owner = EagerBackupWorkloadSubscription(
      workloads: monitor,
      diagnostics: const NoOpEagerBackupDiagnostics(),
      onWorkload: (_) {},
    );
    addTearDown(() async {
      await owner.dispose();
      await monitor.dispose();
    });
    monitor.onListen('A', () => unawaited(owner.replace(null)));

    await owner.replace('A');
    await pumpEventQueue();

    expect(monitor.liveUsers, isEmpty);
  });
}

final class _ControlledWorkloads implements EagerBackupWorkloadMonitorPort {
  final Map<String, _ControlledWorkloadStream> _streams = {};

  Set<String> get liveUsers => _streams.entries.where((entry) => entry.value.live).map((entry) => entry.key).toSet();

  @override
  Stream<BackupWorkload> watch(String userId) => _stream(userId).stream;

  void emit(String userId, BackupWorkload workload) => _stream(userId).emit(workload);

  void blockCancellation(String userId) => _stream(userId).blockCancellation();

  Future<void> cancellationStarted(String userId) => _stream(userId).cancellationStarted;

  void releaseCancellation(String userId) => _stream(userId).releaseCancellation();

  void onListen(String userId, void Function() callback) => _stream(userId).onListen = callback;

  Future<void> dispose() => Future.wait(_streams.values.map((stream) => stream.dispose()));

  _ControlledWorkloadStream _stream(String userId) => _streams.putIfAbsent(userId, _ControlledWorkloadStream.new);
}

final class _ControlledWorkloadStream {
  _ControlledWorkloadStream() {
    _controller = StreamController<BackupWorkload>.broadcast(
      sync: true,
      onListen: () {
        live = true;
        onListen?.call();
      },
      onCancel: () async {
        live = false;
        if (_cancelRelease case final release?) {
          if (!_cancelStarted.isCompleted) _cancelStarted.complete();
          await release.future;
        }
      },
    );
  }

  late final StreamController<BackupWorkload> _controller;
  Completer<void> _cancelStarted = Completer<void>();
  Completer<void>? _cancelRelease;
  void Function()? onListen;
  bool live = false;

  Stream<BackupWorkload> get stream => _controller.stream;
  Future<void> get cancellationStarted => _cancelStarted.future;

  void emit(BackupWorkload workload) => _controller.add(workload);

  void blockCancellation() {
    _cancelStarted = Completer<void>();
    _cancelRelease = Completer<void>();
  }

  void releaseCancellation() {
    final release = _cancelRelease;
    if (release != null && !release.isCompleted) release.complete();
  }

  Future<void> dispose() async {
    releaseCancellation();
    await _controller.close();
  }
}
