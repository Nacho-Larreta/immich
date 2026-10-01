import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';

final class IosBackupOperationLifetimeAdapter implements BackupOperationLifetimePort {
  const IosBackupOperationLifetimeAdapter();

  static const _channel = MethodChannel('com.bbflight.background_downloader');
  static final _engineIdentity = RegExp(
    r'^ios-engine-v1:[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}:[1-9][0-9]*$',
  );
  static final _legacyIdentity = RegExp(r'^pid:[1-9][0-9]*$');

  @override
  Future<String?> currentIdentity() async {
    try {
      final response = await _channel.invokeMethod<Object?>('backupOperationIdentity');
      if (response is! String || !_engineIdentity.hasMatch(response)) return null;
      return response;
    } on MissingPluginException {
      return null;
    } on PlatformException {
      return null;
    }
  }

  @override
  Future<BackupOperationState> stateOf(String identity) async {
    if (!_engineIdentity.hasMatch(identity) && !_legacyIdentity.hasMatch(identity)) {
      return BackupOperationState.unknown;
    }
    try {
      final response = await _channel.invokeMethod<Object?>('backupOperationState', identity);
      return switch (response) {
        'alive' => BackupOperationState.alive,
        'retired' => BackupOperationState.retired,
        _ => BackupOperationState.unknown,
      };
    } on MissingPluginException {
      return BackupOperationState.unknown;
    } on PlatformException {
      return BackupOperationState.unknown;
    }
  }
}
