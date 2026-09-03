import 'package:immich_mobile/domain/models/eager_backup.model.dart';

enum EagerBackupDiagnosticCode {
  bootstrapCreated,
  bootstrapConfiguration,
  triggerReceived,
  phaseChanged,
  connectivitySnapshot,
  connectivityInitializationFailed,
  photoObserverStarted,
  photoObserverStartFailed,
  workloadSubscribed,
  workloadUnsubscribed,
  workloadFirstEmission,
  workloadSubscriptionFailed,
  serverProofChanged,
  admissionDecided,
  uploadFinished,
}

final class EagerBackupDiagnosticEvent {
  const EagerBackupDiagnosticEvent(
    this.code, {
    this.enabled,
    this.userPresent,
    this.trigger,
    this.phase,
    this.blocker,
    this.admissionDisposition,
    this.activeClaims,
    this.ready,
    this.processing,
    this.available,
    this.wifi,
    this.proofAvailable,
    this.uploadOutcome,
  });

  final EagerBackupDiagnosticCode code;
  final bool? enabled;
  final bool? userPresent;
  final EagerBackupTrigger? trigger;
  final EagerBackupPhase? phase;
  final EagerBackupBlocker? blocker;
  final EagerBackupAdmissionDisposition? admissionDisposition;
  final int? activeClaims;
  final int? ready;
  final int? processing;
  final bool? available;
  final bool? wifi;
  final bool? proofAvailable;
  final EagerBackupUploadOutcome? uploadOutcome;
}

abstract interface class EagerBackupDiagnosticsPort {
  void report(EagerBackupDiagnosticEvent event);
}

final class NoOpEagerBackupDiagnostics implements EagerBackupDiagnosticsPort {
  const NoOpEagerBackupDiagnostics();

  @override
  void report(EagerBackupDiagnosticEvent event) {}
}

final class FailSafeEagerBackupDiagnostics implements EagerBackupDiagnosticsPort {
  const FailSafeEagerBackupDiagnostics(this._delegate);

  final EagerBackupDiagnosticsPort _delegate;

  @override
  void report(EagerBackupDiagnosticEvent event) {
    try {
      _delegate.report(event);
    } on Object {
      return;
    }
  }
}
