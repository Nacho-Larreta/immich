import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/domain/services/backup_enablement_controller.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/repositories/backup_enablement.repository.dart';
import 'package:immich_mobile/providers/app_settings.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup.provider.dart';
import 'package:immich_mobile/providers/backup/eager_backup_signal.provider.dart';
import 'package:immich_mobile/providers/infrastructure/db.provider.dart';
import 'package:immich_mobile/services/app_settings.service.dart';
import 'package:immich_mobile/services/background_upload.service.dart';

final _backupEnablementAdapterProvider = Provider<_RiverpodBackupEnablementAdapter>((ref) {
  return _RiverpodBackupEnablementAdapter(ref);
});

final backupEnablementPortProvider = Provider<BackupEnablementPort>((ref) {
  return ref.watch(_backupEnablementAdapterProvider);
});

final backupEnablementAuthorityProvider = Provider<BackupEnablementAuthorityPort>((ref) {
  return ref.watch(_backupEnablementAdapterProvider);
});

final backupEnablementControllerProvider = Provider<BackupEnablementController>((ref) {
  final legacyEnabled = ref.read(appSettingsServiceProvider).getSetting(AppSettingsEnum.enableBackup);
  final controller = BackupEnablementController(
    ref.watch(backupEnablementPortProvider),
    initiallyEnabled: legacyEnabled,
  );
  ref.onDispose(controller.dispose);
  unawaited(controller.initialize(legacyEnabled));
  return controller;
});

final backupEnablementStateProvider = StreamProvider<BackupEnablementState>((ref) async* {
  final controller = ref.watch(backupEnablementControllerProvider);
  yield controller.state;
  yield* controller.states;
});

final class _RiverpodBackupEnablementAdapter implements BackupEnablementPort, BackupEnablementAuthorityPort {
  const _RiverpodBackupEnablementAdapter(this._ref);

  final Ref _ref;

  DriftBackupEnablementRepository get _persistence {
    return DriftBackupEnablementRepository(_ref.read(driftProvider));
  }

  @override
  Future<DurableBackupEnablementState> beginDisable() async {
    final disabling = await _persistence.beginDisable();
    await Store.populateCache();
    return disabling;
  }

  @override
  Future<DurableBackupEnablementState> initialize(bool legacyEnabled) async {
    final state = await _persistence.initialize(legacyEnabled);
    await Store.populateCache();
    return state;
  }

  @override
  Future<DurableBackupEnablementState?> readAuthority() => _persistence.read();

  @override
  Future<bool> admitsBackupWork() => _persistence.admitsBackupWork();

  @override
  Future<bool> completeDrain(DurableBackupEnablementState disabling) {
    return _persistence.completeDrain(disabling);
  }

  @override
  Future<bool> drain() async => await _ref.read(backgroundUploadServiceProvider).cancel() == 0;

  @override
  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained) async {
    final enabled = await _persistence.enableFromDrained(disabledDrained);
    if (enabled) await Store.populateCache();
    return enabled;
  }

  @override
  Future<bool> failDrain(DurableBackupEnablementState disabling) {
    return _persistence.failDrain(disabling);
  }

  @override
  void reportDrainFailed() => _ref.read(eagerBackupCoordinatorProvider).reportDrainFailed();

  @override
  void signalSettingChanged() => _ref.read(eagerBackupSignalProvider).signal(EagerBackupTrigger.settingChanged);

  @override
  void stopEager() => _ref.read(eagerBackupCoordinatorProvider).setEnabled(false);
}
