import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_operation_lifetime.interface.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/ios_backup_operation_lifetime_adapter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  const channel = MethodChannel('com.bbflight.background_downloader');
  final messenger = TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  const adapter = IosBackupOperationLifetimeAdapter();

  tearDown(() => messenger.setMockMethodCallHandler(channel, null));

  test('reads registered engine identity and native retirement evidence', () async {
    const identity = 'ios-engine-v1:123e4567-e89b-12d3-a456-426614174000:2';
    messenger.setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'backupOperationIdentity') return identity;
      expect(call.method, 'backupOperationState');
      expect(call.arguments, identity);
      return 'retired';
    });

    expect(await adapter.currentIdentity(), identity);
    expect(await adapter.stateOf(identity), BackupOperationState.retired);
  });

  test('bridge failure is retryable and never proves an operation retired', () async {
    const identity = 'ios-engine-v1:123e4567-e89b-12d3-a456-426614174000:2';
    messenger.setMockMethodCallHandler(channel, (_) async => throw PlatformException(code: 'unavailable'));
    expect(await adapter.currentIdentity(), isNull);
    expect(await adapter.stateOf(identity), BackupOperationState.unknown);

    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'backupOperationIdentity' ? identity : 'retired',
    );
    expect(await adapter.currentIdentity(), identity);
    expect(await adapter.stateOf(identity), BackupOperationState.retired);
  });

  test('malformed responses and unknown identities fail closed', () async {
    messenger.setMockMethodCallHandler(
      channel,
      (call) async => call.method == 'backupOperationIdentity' ? 'pid:42' : 'retired',
    );
    expect(await adapter.currentIdentity(), isNull);
    expect(await adapter.stateOf('garbage'), BackupOperationState.unknown);
    expect(await adapter.stateOf('pid:42'), BackupOperationState.retired);

    messenger.setMockMethodCallHandler(channel, (_) async => 'unexpected');
    expect(await adapter.stateOf('ios-engine-v1:123e4567-e89b-12d3-a456-426614174000:2'), BackupOperationState.unknown);
  });
}
