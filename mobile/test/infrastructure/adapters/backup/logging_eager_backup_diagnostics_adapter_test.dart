import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/eager_backup_diagnostics.interface.dart';
import 'package:immich_mobile/domain/models/eager_backup.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/logging_eager_backup_diagnostics_adapter.dart';
import 'package:logging/logging.dart';

void main() {
  test('logger emits only the diagnostic allowlist', () async {
    final logger = Logger.detached('EagerBackupTest')..level = Level.ALL;
    final record = logger.onRecord.first;
    final adapter = LoggingEagerBackupDiagnosticsAdapter(logger);

    adapter.report(
      const EagerBackupDiagnosticEvent(
        EagerBackupDiagnosticCode.phaseChanged,
        enabled: true,
        userPresent: true,
        trigger: EagerBackupTrigger.startup,
        phase: EagerBackupPhase.blocked,
        blocker: EagerBackupBlocker.noProof,
        admissionDisposition: EagerBackupAdmissionDisposition.backgroundAdopted,
        activeClaims: 1,
        ready: 2,
        processing: 0,
        available: true,
        wifi: true,
        proofAvailable: false,
        uploadOutcome: EagerBackupUploadOutcome.evidenceUnavailable,
      ),
    );

    final message = (await record).message;
    final fields = message.split(' ').skip(1).map((field) => field.split('=').first).toSet();
    expect(fields, {
      'code',
      'enabled',
      'user_present',
      'trigger',
      'phase',
      'blocker',
      'admission_disposition',
      'active_claims',
      'ready',
      'processing',
      'available',
      'wifi',
      'proof_available',
      'upload_outcome',
    });
    expect(message, isNot(contains('user-a')));
    expect(message, isNot(contains('https://')));
    expect(message, isNot(contains('token')));
  });

  test('hot events are fine and identical effective transitions are deduplicated', () async {
    final logger = Logger.detached('EagerBackupTest')..level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final adapter = LoggingEagerBackupDiagnosticsAdapter(logger);
    const event = EagerBackupDiagnosticEvent(
      EagerBackupDiagnosticCode.connectivitySnapshot,
      available: true,
      wifi: true,
    );

    adapter
      ..report(event)
      ..report(event);

    expect(records, hasLength(1));
    expect(records.single.level, Level.FINE);
  });

  test('blocked phases and upload outcomes remain visible at info', () {
    final logger = Logger.detached('EagerBackupTest')..level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final adapter = LoggingEagerBackupDiagnosticsAdapter(logger);

    adapter
      ..report(
        const EagerBackupDiagnosticEvent(
          EagerBackupDiagnosticCode.phaseChanged,
          phase: EagerBackupPhase.blocked,
          blocker: EagerBackupBlocker.noProof,
        ),
      )
      ..report(
        const EagerBackupDiagnosticEvent(
          EagerBackupDiagnosticCode.uploadFinished,
          uploadOutcome: EagerBackupUploadOutcome.completed,
        ),
      );

    expect(records.map((record) => record.level), [Level.INFO, Level.INFO]);
  });

  test('same phase and blocker do not repeat info when only workload counts change', () {
    final logger = Logger.detached('EagerBackupTest')..level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final adapter = LoggingEagerBackupDiagnosticsAdapter(logger);

    adapter
      ..report(
        const EagerBackupDiagnosticEvent(
          EagerBackupDiagnosticCode.phaseChanged,
          phase: EagerBackupPhase.blocked,
          blocker: EagerBackupBlocker.noProof,
          ready: 1,
        ),
      )
      ..report(
        const EagerBackupDiagnosticEvent(
          EagerBackupDiagnosticCode.phaseChanged,
          phase: EagerBackupPhase.blocked,
          blocker: EagerBackupBlocker.noProof,
          ready: 2,
        ),
      );

    expect(records, hasLength(1));
    expect(records.single.level, Level.INFO);
  });

  test('bootstrap failures are warning without raw errors', () {
    final logger = Logger.detached('EagerBackupTest')..level = Level.ALL;
    final records = <LogRecord>[];
    final subscription = logger.onRecord.listen(records.add);
    addTearDown(subscription.cancel);
    final adapter = LoggingEagerBackupDiagnosticsAdapter(logger);

    adapter.report(const EagerBackupDiagnosticEvent(EagerBackupDiagnosticCode.photoObserverStartFailed));

    expect(records.single.level, Level.WARNING);
    expect(records.single.error, isNull);
    expect(records.single.stackTrace, isNull);
  });
}
