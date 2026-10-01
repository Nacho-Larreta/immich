import 'dart:io';

import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';

final class ProcessBackupOperationLifetimeAdapter implements BackupOperationLifetimePort {
  ProcessBackupOperationLifetimeAdapter() : _identity = 'pid:$pid';

  final String _identity;

  @override
  Future<String?> currentIdentity() async => _identity;

  @override
  Future<BackupOperationState> stateOf(String identity) async =>
      identity == _identity ? BackupOperationState.alive : BackupOperationState.retired;
}
