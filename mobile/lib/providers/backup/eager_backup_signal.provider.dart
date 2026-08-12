import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';

final eagerBackupSignalProvider = Provider<EagerBackupSignalBus>((ref) {
  final bus = EagerBackupSignalBus();
  ref.onDispose(bus.dispose);
  return bus;
});

final class EagerBackupSignalBus {
  final StreamController<EagerBackupTrigger> _controller = StreamController.broadcast(sync: true);

  Stream<EagerBackupTrigger> get events => _controller.stream;

  void signal(EagerBackupTrigger trigger) {
    if (!_controller.isClosed) _controller.add(trigger);
  }

  void dispose() => unawaited(_controller.close());
}
