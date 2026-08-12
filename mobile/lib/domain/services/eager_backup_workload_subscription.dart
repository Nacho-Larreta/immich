import 'dart:async';

import 'package:immich_mobile/domain/interfaces/eager_backup.interface.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';

final class EagerBackupWorkloadSubscription {
  EagerBackupWorkloadSubscription({
    required EagerBackupWorkloadMonitorPort workloads,
    required EagerBackupDiagnosticsPort diagnostics,
    required void Function(BackupWorkload workload) onWorkload,
  }) : _workloads = workloads,
       _diagnostics = FailSafeEagerBackupDiagnostics(diagnostics),
       _onWorkload = onWorkload;

  final EagerBackupWorkloadMonitorPort _workloads;
  final EagerBackupDiagnosticsPort _diagnostics;
  final void Function(BackupWorkload workload) _onWorkload;

  StreamSubscription<BackupWorkload>? _subscription;
  int _generation = 0;
  bool _disposed = false;

  Future<bool> replace(String? userId) async {
    final generation = ++_generation;
    final previous = _subscription;
    _subscription = null;
    await previous?.cancel();
    if (!_isCurrent(generation)) return false;

    if (userId == null) {
      _diagnostics.report(
        const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.workloadUnsubscribed, userPresent: false),
      );
      return true;
    }

    var firstEmission = true;
    late final StreamSubscription<BackupWorkload> created;
    created = _workloads
        .watch(userId)
        .listen(
          (workload) {
            if (!_isCurrent(generation)) return;
            if (firstEmission) {
              firstEmission = false;
              _diagnostics.report(
                EagerBackupDiagnosticEvent(
                  EagerBackupDiagnosticCode.workloadFirstEmission,
                  ready: workload.ready,
                  processing: workload.processing,
                ),
              );
            }
            _onWorkload(workload);
          },
          onError: (_, _) {
            if (_isCurrent(generation)) {
              _diagnostics.report(
                const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.workloadSubscriptionFailed),
              );
            }
          },
        );
    if (!_isCurrent(generation)) {
      await created.cancel();
      return false;
    }
    _subscription = created;
    _diagnostics.report(
      const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.workloadSubscribed, userPresent: true),
    );
    return true;
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _generation++;
    final subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
  }

  bool _isCurrent(int generation) => !_disposed && generation == _generation;
}
