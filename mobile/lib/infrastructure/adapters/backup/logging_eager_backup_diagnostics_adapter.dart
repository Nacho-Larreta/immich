import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:logging/logging.dart';

final class LoggingEagerBackupDiagnosticsAdapter implements EagerBackupDiagnosticsPort {
  LoggingEagerBackupDiagnosticsAdapter(Logger logger) : _logger = logger;

  final Logger _logger;
  final Map<EagerBackupDiagnosticCode, String> _lastFingerprints = {};

  @override
  void report(EagerBackupDiagnosticEvent event) {
    final message =
        'eager_backup code=${event.code.name}'
        ' enabled=${_value(event.enabled)}'
        ' user_present=${_value(event.userPresent)}'
        ' trigger=${event.trigger?.name ?? 'none'}'
        ' phase=${event.phase?.name ?? 'none'}'
        ' blocker=${event.blocker?.name ?? 'none'}'
        ' ready=${_value(event.ready)}'
        ' processing=${_value(event.processing)}'
        ' available=${_value(event.available)}'
        ' wifi=${_value(event.wifi)}'
        ' proof_available=${_value(event.proofAvailable)}'
        ' upload_outcome=${event.uploadOutcome?.name ?? 'none'}';
    if (_deduplicates(event.code)) {
      final fingerprint = _fingerprint(event, message);
      if (_lastFingerprints[event.code] == fingerprint) return;
      _lastFingerprints[event.code] = fingerprint;
    }

    switch (event.code) {
      case EagerBackupDiagnosticCode.connectivityInitializationFailed ||
          EagerBackupDiagnosticCode.photoObserverStartFailed ||
          EagerBackupDiagnosticCode.workloadSubscriptionFailed:
        _logger.warning(message);
      case EagerBackupDiagnosticCode.uploadFinished:
        _logger.info(message);
      case EagerBackupDiagnosticCode.phaseChanged when event.blocker != null:
        _logger.info(message);
      default:
        _logger.fine(message);
    }
  }

  static String _value(Object? value) => value?.toString() ?? 'none';

  static bool _deduplicates(EagerBackupDiagnosticCode code) => switch (code) {
    EagerBackupDiagnosticCode.triggerReceived ||
    EagerBackupDiagnosticCode.phaseChanged ||
    EagerBackupDiagnosticCode.connectivitySnapshot ||
    EagerBackupDiagnosticCode.workloadSubscribed ||
    EagerBackupDiagnosticCode.workloadUnsubscribed ||
    EagerBackupDiagnosticCode.workloadFirstEmission ||
    EagerBackupDiagnosticCode.serverProofChanged => true,
    _ => false,
  };

  static String _fingerprint(EagerBackupDiagnosticEvent event, String message) {
    if (event.code != EagerBackupDiagnosticCode.phaseChanged) return message;
    return '${event.phase?.name ?? 'none'}:${event.blocker?.name ?? 'none'}';
  }
}
