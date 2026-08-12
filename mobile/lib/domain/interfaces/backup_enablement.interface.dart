import 'package:immich_mobile/domain/models/backup_enablement.model.dart';

abstract interface class BackupEnablementAuthorityPort {
  Future<DurableBackupEnablementState?> readAuthority();
}

abstract interface class BackupEnablementPort {
  Future<DurableBackupEnablementState> initialize(bool legacyEnabled);

  Future<DurableBackupEnablementState> beginDisable();

  Future<bool> completeDrain(DurableBackupEnablementState disabling);

  Future<bool> failDrain(DurableBackupEnablementState disabling);

  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained);

  Future<bool> admitsBackupWork();

  void stopEager();

  Future<bool> drain();

  void reportDrainFailed();

  void signalSettingChanged();
}
