enum BackupOperationState { alive, retired, unknown }

abstract interface class BackupOperationLifetimePort {
  Future<String?> currentIdentity();

  Future<BackupOperationState> stateOf(String identity);
}
