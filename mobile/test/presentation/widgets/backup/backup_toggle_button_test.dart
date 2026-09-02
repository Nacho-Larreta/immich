import 'dart:async';

import 'package:easy_localization/easy_localization.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_execution.interface.dart';
import 'package:immich_mobile/domain/interfaces/backup_run_binding.interface.dart';
import 'package:immich_mobile/domain/services/backup_enablement_controller.dart';
import 'package:immich_mobile/domain/services/backup_execution_arbiter.dart';
import 'package:immich_mobile/generated/codegen_loader.g.dart';
import 'package:immich_mobile/presentation/widgets/backup/backup_toggle_button.widget.dart';
import 'package:immich_mobile/providers/backup/backup_enablement.provider.dart';
import 'package:immich_mobile/providers/backup/drift_backup.provider.dart';
import 'package:immich_mobile/services/background_upload.service.dart';
import 'package:immich_mobile/services/foreground_upload.service.dart';
import 'package:immich_mobile/utils/upload_speed_calculator.dart';
import 'package:mocktail/mocktail.dart';

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(
      const MethodChannel('plugins.flutter.io/shared_preferences'),
      (_) async => <String, Object>{},
    );
    await EasyLocalization.ensureInitialized();
  });

  testWidgets('busy disables tile and switch, drain failure stays OFF and exposes retry', (tester) async {
    final drain = Completer<bool>();
    final port = _EnablementPort(drain.future);
    final controller = BackupEnablementController(port, initiallyEnabled: true);
    addTearDown(controller.dispose);
    final drift = DriftBackupNotifier(
      _ForegroundUploads(),
      _BackgroundUploads(),
      UploadSpeedManager(),
      BackupExecutionArbiter(leases: _Leases(), tasks: _Registry()),
      _Bindings(),
      port,
    );

    await tester.pumpWidget(_harness(controller, drift));
    await tester.pump();
    expect(tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch'))).value, isTrue);

    await tester.tap(find.byType(InkWell));
    await tester.pump();
    final busySwitch = tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch')));
    expect(busySwitch.value, isFalse);
    expect(busySwitch.onChanged, isNull);
    expect(tester.widget<InkWell>(find.byType(InkWell)).onTap, isNull);

    drain.complete(false);
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('backup-drain-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-drain-retry')), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch'))).value, isFalse);
    expect(tester.takeException(), isNull);
  });

  testWidgets('persistence failure before OFF fence keeps switch ON and exposes retry without throwing', (
    tester,
  ) async {
    final port = _EnablementPort(Future.value(true), beginDisableError: StateError('database unavailable'));
    final controller = BackupEnablementController(port, initiallyEnabled: true);
    addTearDown(controller.dispose);
    final drift = DriftBackupNotifier(
      _ForegroundUploads(),
      _BackgroundUploads(),
      UploadSpeedManager(),
      BackupExecutionArbiter(leases: _Leases(), tasks: _Registry()),
      _Bindings(),
      port,
    );

    await tester.pumpWidget(_harness(controller, drift));
    await tester.pump();
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();

    expect(find.byKey(const ValueKey('backup-disable-error')), findsOneWidget);
    expect(find.byKey(const ValueKey('backup-disable-retry')), findsOneWidget);
    expect(tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch'))).value, isTrue);
    expect(tester.takeException(), isNull);
    expect(port.drainCalls, 0);
  });

  testWidgets('drain failure keeps the ON switch available and reflects serialized recovery result', (tester) async {
    final retryDrain = Completer<bool>();
    final port = _EnablementPort(Future.value(false), subsequentDrainResults: [retryDrain.future]);
    final controller = BackupEnablementController(port, initiallyEnabled: true);
    addTearDown(controller.dispose);
    final drift = DriftBackupNotifier(
      _ForegroundUploads(),
      _BackgroundUploads(),
      UploadSpeedManager(),
      BackupExecutionArbiter(leases: _Leases(), tasks: _Registry()),
      _Bindings(),
      port,
    );

    await tester.pumpWidget(_harness(controller, drift));
    await tester.pump();
    await tester.tap(find.byType(InkWell));
    await tester.pumpAndSettle();

    final failedSwitch = tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch')));
    expect(failedSwitch.value, isFalse);
    expect(failedSwitch.onChanged, isNotNull);

    await tester.tap(find.byKey(const ValueKey('backup-enablement-switch')));
    await tester.pump();

    final busySwitch = tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch')));
    expect(busySwitch.value, isFalse);
    expect(busySwitch.onChanged, isNull);
    expect(port.drainCalls, 2);
    expect(port.enableCalls, 0);

    retryDrain.complete(true);
    await tester.pumpAndSettle();

    expect(tester.widget<Switch>(find.byKey(const ValueKey('backup-enablement-switch'))).value, isTrue);
    expect(port.enableCalls, 1);
    expect(tester.takeException(), isNull);
  });
}

Widget _harness(BackupEnablementController controller, DriftBackupNotifier drift) => ProviderScope(
  overrides: [
    backupEnablementControllerProvider.overrideWithValue(controller),
    driftBackupProvider.overrideWith((_) => drift),
  ],
  child: EasyLocalization(
    supportedLocales: const [Locale('en')],
    fallbackLocale: const Locale('en'),
    startLocale: const Locale('en'),
    path: 'unused',
    saveLocale: false,
    assetLoader: const CodegenLoader(),
    child: Builder(
      builder: (context) => MaterialApp(
        localizationsDelegates: context.localizationDelegates,
        supportedLocales: context.supportedLocales,
        locale: context.locale,
        home: const Scaffold(body: BackupToggleButton()),
      ),
    ),
  ),
);

final class _EnablementPort implements BackupEnablementPort, BackupEnablementAuthorityPort {
  _EnablementPort(this.drainResult, {this.beginDisableError, List<Future<bool>> subsequentDrainResults = const []})
    : _subsequentDrainResults = List.of(subsequentDrainResults);

  final Future<bool> drainResult;
  final List<Future<bool>> _subsequentDrainResults;
  final Object? beginDisableError;
  int drainCalls = 0;
  int enableCalls = 0;

  @override
  Future<DurableBackupEnablementState> initialize(bool legacyEnabled) async {
    return DurableBackupEnablementState(
      phase: legacyEnabled ? DurableBackupEnablementPhase.enabled : DurableBackupEnablementPhase.disabling,
      generation: 0,
    );
  }

  @override
  Future<DurableBackupEnablementState?> readAuthority() async =>
      const DurableBackupEnablementState(phase: DurableBackupEnablementPhase.enabled, generation: 0);

  @override
  Future<bool> admitsBackupWork() async => false;

  @override
  Future<DurableBackupEnablementState> beginDisable() async {
    if (beginDisableError case final error?) throw error;
    return const DurableBackupEnablementState(phase: DurableBackupEnablementPhase.disabling, generation: 1);
  }

  @override
  Future<bool> completeDrain(DurableBackupEnablementState disabling) async => true;

  @override
  Future<bool> drain() {
    drainCalls++;
    return drainCalls == 1 ? drainResult : _subsequentDrainResults.removeAt(0);
  }

  @override
  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained) async {
    enableCalls++;
    return true;
  }

  @override
  Future<bool> failDrain(DurableBackupEnablementState disabling) async => true;

  @override
  void reportDrainFailed() {}

  @override
  void signalSettingChanged() {}

  @override
  void stopEager() {}
}

class _ForegroundUploads extends Mock implements ForegroundUploadService {}

class _BackgroundUploads extends Mock implements BackgroundUploadService {}

class _Leases extends Mock implements BackupExecutionLeasePort {}

class _Registry extends Mock implements BackupTaskRegistryPort {}

class _Bindings extends Mock implements BackupRunBindingSourcePort {}
