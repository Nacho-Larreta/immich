import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/services/backup_enablement_controller.dart';

void main() {
  test('OFF persists first, stops eager, shares one drain, and reaches disabled', () async {
    final drain = Completer<bool>();
    final port = _EnablementPort(enabled: true, drainResult: drain.future);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);

    final tile = controller.disable();
    final toggle = controller.disable();

    expect(controller.state.status, BackupEnablementStatus.disabling);
    await Future<void>.delayed(Duration.zero);
    expect(port.events, ['begin-disable', 'stop-eager', 'drain']);
    drain.complete(true);
    expect(await tile, BackupEnablementResult.applied);
    expect(await toggle, BackupEnablementResult.applied);
    expect(port.drainCalls, 1);
    expect(controller.state, const BackupEnablementState.disabled());
  });

  test('failed OFF drain remains disabled, exposes retry, and never throws', () async {
    final port = _EnablementPort(enabled: true, drainResult: Future.value(false));
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);

    expect(await controller.disable(), BackupEnablementResult.drainFailed);
    expect(port.enabled, isFalse);
    expect(controller.state, const BackupEnablementState.drainFailed());
  });

  test('OFF persistence failure before the fence remains truthfully enabled and never drains', () async {
    final port = _EnablementPort(enabled: true, beginDisableError: StateError('database unavailable'));
    final controller = BackupEnablementController(port, initiallyEnabled: true);
    addTearDown(controller.dispose);

    expect(await controller.disable(), BackupEnablementResult.disableFailedBeforeFence);
    expect(port.enabled, isTrue);
    expect(port.drainCalls, 0);
    expect(port.events, ['begin-disable']);
    expect(controller.state, const BackupEnablementState.disableFailedBeforeFence());
  });

  test('retry drains only and never enables', () async {
    final port = _EnablementPort(enabled: true, drainResults: [false, true]);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);
    await controller.disable();
    port.events.clear();

    expect(await controller.retryDrain(), BackupEnablementResult.applied);
    expect(port.events, ['begin-disable', 'stop-eager', 'drain', 'complete-drain']);
    expect(port.enabled, isFalse);
    expect(controller.state, const BackupEnablementState.disabled());
  });

  test('cold start OFF reconciles orphaned work without persisting or enabling', () async {
    final port = _EnablementPort(enabled: false, drainResults: [true]);
    final controller = BackupEnablementController(port, initiallyEnabled: false);
    addTearDown(controller.dispose);

    expect(await controller.reconcileDisabled(), BackupEnablementResult.applied);
    expect(port.events, ['begin-disable', 'stop-eager', 'drain', 'complete-drain']);
    expect(port.enabled, isFalse);
    expect(controller.state, const BackupEnablementState.disabled());
  });

  test('ON is busy while disabling and recovers a failed drain before enabling', () async {
    final pendingDrain = Completer<bool>();
    final port = _EnablementPort(enabled: true, drainResult: pendingDrain.future, drainResults: [true]);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);

    final disabling = controller.disable();
    expect(await controller.enable(), BackupEnablementResult.busy);
    expect(port.enabled, isFalse);
    pendingDrain.complete(false);
    await disabling;

    port.drainResult = null;
    expect(await controller.enable(), BackupEnablementResult.applied);
    expect(port.enabled, isTrue);
    expect(
      port.events,
      containsAllInOrder(['fail-drain', 'begin-disable', 'stop-eager', 'drain', 'complete-drain', 'enable', 'signal']),
    );
    expect(controller.state, const BackupEnablementState.enabled());
  });

  test('failed ON recovery remains OFF and never reaches enableFromDrained', () async {
    final port = _EnablementPort(enabled: true, drainResults: [false, false]);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);
    await controller.disable();
    port.events.clear();

    expect(await controller.enable(), BackupEnablementResult.drainFailed);

    expect(port.enabled, isFalse);
    expect(port.events, ['begin-disable', 'stop-eager', 'drain', 'fail-drain', 'report-drain-failed']);
    expect(controller.state, const BackupEnablementState.drainFailed());
  });

  test('failed enableFromDrained after ON recovery remains OFF', () async {
    final port = _EnablementPort(enabled: true, drainResults: [false, true], enableResult: false);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);
    await controller.disable();

    expect(await controller.enable(), BackupEnablementResult.drainRequired);

    expect(port.enabled, isFalse);
    expect(controller.state, const BackupEnablementState.drainFailed());
  });

  test('enable CAS miss remains retryable and the next serialized ON safely drains again', () async {
    final port = _EnablementPort(enabled: true, drainResults: [false, true, true], enableResults: [false, true]);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);
    await controller.disable();

    expect(await controller.enable(), BackupEnablementResult.drainRequired);
    expect(controller.state, const BackupEnablementState.drainFailed());

    final retry = controller.enable();
    expect(await controller.enable(), BackupEnablementResult.busy);
    expect(await retry, BackupEnablementResult.applied);

    expect(port.enabled, isTrue);
    expect(port.drainCalls, 3);
    expect(port.events.where((event) => event == 'enable'), hasLength(2));
    expect(controller.state, const BackupEnablementState.enabled());
  });

  test('concurrent ON taps share one serialized failed-drain recovery', () async {
    final retryDrain = Completer<bool>();
    final port = _EnablementPort(enabled: true, drainResults: [false]);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    addTearDown(controller.dispose);
    await controller.disable();
    port.drainResult = retryDrain.future;
    port.events.clear();

    final first = controller.enable();
    final second = controller.enable();
    await Future<void>.delayed(Duration.zero);

    expect(await second, BackupEnablementResult.busy);
    expect(port.drainCalls, 2);
    retryDrain.complete(true);
    expect(await first, BackupEnablementResult.applied);
    expect(port.events.where((event) => event == 'enable'), hasLength(1));
  });

  test('stale drained controller cannot enable after a newer disable generation', () async {
    final port = _EnablementPort(enabled: true, drainResult: Future.value(true));
    final controller = BackupEnablementController(port, initiallyEnabled: true);
    addTearDown(controller.dispose);

    expect(await controller.disable(), BackupEnablementResult.applied);
    await port.beginDisable();

    expect(await controller.enable(), BackupEnablementResult.drainRequired);
    expect(port.enabled, isFalse);
    expect(controller.state, const BackupEnablementState.drainFailed());
  });

  test('late completion after dispose does not publish state', () async {
    final drain = Completer<bool>();
    final port = _EnablementPort(enabled: true, drainResult: drain.future);
    final controller = BackupEnablementController(port, initiallyEnabled: port.enabled);
    final states = <BackupEnablementState>[];
    final subscription = controller.states.listen(states.add);

    final operation = controller.disable();
    await Future<void>.delayed(Duration.zero);
    await controller.dispose();
    drain.complete(true);
    await operation;
    await subscription.cancel();

    expect(states, [const BackupEnablementState.disabling()]);
  });
}

final class _EnablementPort implements BackupEnablementPort {
  _EnablementPort({
    required this.enabled,
    this.drainResult,
    List<bool>? drainResults,
    this.beginDisableError,
    this.enableResult = true,
    List<bool>? enableResults,
  }) : _drainResults = List.of(drainResults ?? const []),
       _enableResults = List.of(enableResults ?? const []);

  bool enabled;
  Future<bool>? drainResult;
  final List<bool> _drainResults;
  final Object? beginDisableError;
  final bool enableResult;
  final List<bool> _enableResults;
  final List<String> events = [];
  int drainCalls = 0;
  int generation = 0;

  @override
  Future<DurableBackupEnablementState> initialize(bool legacyEnabled) async {
    return DurableBackupEnablementState(
      phase: legacyEnabled ? DurableBackupEnablementPhase.enabled : DurableBackupEnablementPhase.disabling,
      generation: generation,
    );
  }

  @override
  Future<bool> admitsBackupWork() async => enabled;

  @override
  Future<DurableBackupEnablementState> beginDisable() async {
    events.add('begin-disable');
    if (beginDisableError case final error?) throw error;
    enabled = false;
    return DurableBackupEnablementState(phase: DurableBackupEnablementPhase.disabling, generation: ++generation);
  }

  @override
  Future<bool> completeDrain(DurableBackupEnablementState disabling) async {
    events.add('complete-drain');
    return disabling.generation == generation;
  }

  @override
  Future<bool> drain() {
    events.add('drain');
    drainCalls++;
    return drainResult ?? Future.value(_drainResults.removeAt(0));
  }

  @override
  Future<bool> enableFromDrained(DurableBackupEnablementState disabledDrained) async {
    events.add('enable');
    if (disabledDrained.generation != generation ||
        disabledDrained.phase != DurableBackupEnablementPhase.disabledDrained) {
      return false;
    }
    final result = _enableResults.isEmpty ? enableResult : _enableResults.removeAt(0);
    if (!result) return false;
    enabled = true;
    generation++;
    return true;
  }

  @override
  Future<bool> failDrain(DurableBackupEnablementState disabling) async {
    events.add('fail-drain');
    return disabling.generation == generation;
  }

  @override
  void signalSettingChanged() => events.add('signal');

  @override
  void reportDrainFailed() => events.add('report-drain-failed');

  @override
  void stopEager() => events.add('stop-eager');
}
