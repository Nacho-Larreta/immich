import 'dart:convert';

enum BackupEnablementStatus { enabled, disableFailedBeforeFence, disabling, disabled, drainFailed }

enum BackupEnablementResult {
  applied,
  alreadyApplied,
  busy,
  disableFailedBeforeFence,
  drainFailed,
  drainRequired,
  persistenceFailed,
}

final class BackupEnablementState {
  const BackupEnablementState._(this.status, this.isBusy);

  const BackupEnablementState.enabled() : this._(BackupEnablementStatus.enabled, false);

  const BackupEnablementState.disableFailedBeforeFence()
    : this._(BackupEnablementStatus.disableFailedBeforeFence, false);

  const BackupEnablementState.disabling() : this._(BackupEnablementStatus.disabling, true);

  const BackupEnablementState.disabled({bool isBusy = false}) : this._(BackupEnablementStatus.disabled, isBusy);

  const BackupEnablementState.drainFailed() : this._(BackupEnablementStatus.drainFailed, false);

  final BackupEnablementStatus status;
  final bool isBusy;

  bool get isEnabled =>
      status == BackupEnablementStatus.enabled || status == BackupEnablementStatus.disableFailedBeforeFence;
  bool get canRetryDrain => status == BackupEnablementStatus.drainFailed && !isBusy;
  bool get canRetryDisable => status == BackupEnablementStatus.disableFailedBeforeFence && !isBusy;

  @override
  bool operator ==(Object other) =>
      identical(this, other) || other is BackupEnablementState && status == other.status && isBusy == other.isBusy;

  @override
  int get hashCode => Object.hash(status, isBusy);
}

enum DurableBackupEnablementPhase { enabled, disabling, disabledDrained, drainFailed }

final class DurableBackupEnablementState {
  const DurableBackupEnablementState({required this.phase, required this.generation});

  static const schemaVersion = 1;

  final DurableBackupEnablementPhase phase;
  final int generation;

  DurableBackupEnablementState transitionTo(DurableBackupEnablementPhase nextPhase, {bool advance = false}) {
    return DurableBackupEnablementState(phase: nextPhase, generation: advance ? generation + 1 : generation);
  }

  String toJson() => jsonEncode({'schemaVersion': schemaVersion, 'phase': phase.name, 'generation': generation});

  static DurableBackupEnablementState? tryParse(String? source) {
    if (source == null || source.isEmpty) return null;
    try {
      final json = jsonDecode(source);
      if (json is! Map<String, dynamic> || json['schemaVersion'] != schemaVersion) return null;
      final generation = json['generation'];
      if (generation is! int || generation < 0) return null;
      return DurableBackupEnablementState(
        phase: DurableBackupEnablementPhase.values.byName(json['phase'] as String),
        generation: generation,
      );
    } on Object {
      return null;
    }
  }

  @override
  bool operator ==(Object other) =>
      other is DurableBackupEnablementState && phase == other.phase && generation == other.generation;

  @override
  int get hashCode => Object.hash(phase, generation);
}
