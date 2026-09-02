import 'dart:async';

import 'package:immich_mobile/domain/interfaces/backup_enablement.interface.dart';
import 'package:immich_mobile/domain/models/backup_enablement.model.dart';

export 'package:immich_mobile/domain/models/backup_enablement.model.dart';

final class BackupEnablementController {
  BackupEnablementController(this._port, {required bool initiallyEnabled})
    : _state = initiallyEnabled ? const BackupEnablementState.enabled() : const BackupEnablementState.disabled();

  final BackupEnablementPort _port;
  final StreamController<BackupEnablementState> _states = StreamController.broadcast(sync: true);
  BackupEnablementState _state;
  Future<BackupEnablementResult>? _operation;
  bool? _operationTarget;
  bool _disposed = false;
  DurableBackupEnablementState? _drainedState;

  BackupEnablementState get state => _state;
  Stream<BackupEnablementState> get states => _states.stream;

  Future<void> initialize(bool legacyEnabled) async {
    final durable = await _port.initialize(legacyEnabled);
    switch (durable.phase) {
      case DurableBackupEnablementPhase.enabled:
        _drainedState = null;
        _publish(const BackupEnablementState.enabled());
      case DurableBackupEnablementPhase.disabledDrained:
        _drainedState = durable;
        _publish(const BackupEnablementState.disabled());
      case DurableBackupEnablementPhase.disabling || DurableBackupEnablementPhase.drainFailed:
        _drainedState = null;
        _publish(const BackupEnablementState.disabled());
        await reconcileDisabled();
    }
  }

  Future<BackupEnablementResult> setEnabled(bool value) => value ? enable() : disable();

  Future<BackupEnablementResult> reconcileDisabled() {
    if (_operation != null) return Future.value(BackupEnablementResult.busy);
    if (_state.status != BackupEnablementStatus.disabled) {
      return Future.value(BackupEnablementResult.alreadyApplied);
    }
    return _start(target: false, operation: _retryDrain);
  }

  Future<BackupEnablementResult> disable() {
    final active = _operation;
    if (active != null) {
      return _operationTarget == false ? active : Future.value(BackupEnablementResult.busy);
    }
    if (_state.status == BackupEnablementStatus.disabled) {
      return Future.value(BackupEnablementResult.alreadyApplied);
    }
    if (_state.status == BackupEnablementStatus.drainFailed) {
      return Future.value(BackupEnablementResult.drainRequired);
    }
    return _start(target: false, operation: _disable);
  }

  Future<BackupEnablementResult> enable() {
    if (_operation != null) return Future.value(BackupEnablementResult.busy);
    if (_state.status == BackupEnablementStatus.disabling) {
      return Future.value(BackupEnablementResult.drainRequired);
    }
    if (_state.status == BackupEnablementStatus.enabled) {
      return Future.value(BackupEnablementResult.alreadyApplied);
    }
    return _start(
      target: true,
      operation: _state.status == BackupEnablementStatus.drainFailed ? _retryDrainAndEnable : _enable,
    );
  }

  Future<BackupEnablementResult> retryDrain() {
    final active = _operation;
    if (active != null) return _operationTarget == false ? active : Future.value(BackupEnablementResult.busy);
    if (_state.status != BackupEnablementStatus.drainFailed) {
      return Future.value(BackupEnablementResult.alreadyApplied);
    }
    return _start(target: false, operation: _retryDrain);
  }

  Future<BackupEnablementResult> _start({
    required bool target,
    required Future<BackupEnablementResult> Function() operation,
  }) {
    _operationTarget = target;
    final active = operation();
    _operation = active;
    active.whenComplete(() {
      if (identical(_operation, active)) {
        _operation = null;
        _operationTarget = null;
      }
    });
    return active;
  }

  Future<BackupEnablementResult> _disable() async {
    _publish(const BackupEnablementState.disabling());
    late final DurableBackupEnablementState disabling;
    try {
      disabling = await _port.beginDisable();
      _port.stopEager();
    } on Object {
      _publish(const BackupEnablementState.disableFailedBeforeFence());
      return BackupEnablementResult.disableFailedBeforeFence;
    }
    return _drain(disabling);
  }

  Future<BackupEnablementResult> _retryDrain() async {
    _publish(const BackupEnablementState.disabling());
    late final DurableBackupEnablementState disabling;
    try {
      disabling = await _port.beginDisable();
      _port.stopEager();
    } on Object {
      _publish(const BackupEnablementState.drainFailed());
      return BackupEnablementResult.persistenceFailed;
    }
    return _drain(disabling);
  }

  Future<BackupEnablementResult> _retryDrainAndEnable() async {
    final drainResult = await _retryDrain();
    if (drainResult != BackupEnablementResult.applied) return drainResult;
    return _enable();
  }

  Future<BackupEnablementResult> _drain(DurableBackupEnablementState disabling) async {
    try {
      if (!await _port.drain()) {
        await _port.failDrain(disabling);
        _drainedState = null;
        _publish(const BackupEnablementState.drainFailed());
        _reportDrainFailed();
        return BackupEnablementResult.drainFailed;
      }
    } on Object {
      await _failDrain(disabling);
      _drainedState = null;
      _publish(const BackupEnablementState.drainFailed());
      _reportDrainFailed();
      return BackupEnablementResult.drainFailed;
    }
    if (!await _port.completeDrain(disabling)) {
      _drainedState = null;
      _publish(const BackupEnablementState.drainFailed());
      _reportDrainFailed();
      return BackupEnablementResult.drainFailed;
    }
    _drainedState = disabling.transitionTo(DurableBackupEnablementPhase.disabledDrained);
    _publish(const BackupEnablementState.disabled());
    return BackupEnablementResult.applied;
  }

  Future<BackupEnablementResult> _enable() async {
    _publish(const BackupEnablementState.disabled(isBusy: true));
    final drained = _drainedState;
    if (drained == null) {
      _publish(const BackupEnablementState.disabled());
      return BackupEnablementResult.drainRequired;
    }
    try {
      if (!await _port.enableFromDrained(drained)) {
        _drainedState = null;
        _publish(const BackupEnablementState.drainFailed());
        return BackupEnablementResult.drainRequired;
      }
    } on Object {
      _publish(const BackupEnablementState.disabled());
      return BackupEnablementResult.persistenceFailed;
    }
    _drainedState = null;
    _publish(const BackupEnablementState.enabled());
    try {
      _port.signalSettingChanged();
    } on Object {
      return BackupEnablementResult.applied;
    }
    return BackupEnablementResult.applied;
  }

  void _reportDrainFailed() {
    try {
      _port.reportDrainFailed();
    } on Object {
      return;
    }
  }

  Future<void> _failDrain(DurableBackupEnablementState disabling) async {
    try {
      await _port.failDrain(disabling);
    } on Object {
      return;
    }
  }

  void _publish(BackupEnablementState next) {
    if (_disposed || next == _state) return;
    _state = next;
    _states.add(next);
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _states.close();
  }
}
