import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/confirmed_server_access.model.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/backup/backup_run_binding_source_adapter.dart';
import 'package:immich_mobile/infrastructure/repositories/network.repository.dart';
import 'package:immich_mobile/providers/backup/backup_run_binding.provider.dart';

void main() {
  test('same endpoint with a newer proof generation invalidates the captured binding', () {
    var generation = 4;
    final source = BackupRunBindingSourceAdapter(() => _snapshot(nativeGeneration: generation));
    final first = source.capture();

    generation = 5;

    expect(first, isNotNull);
    expect(source.isCurrent(first!), isFalse);
    expect(source.capture()!.apiEndpoint, first.apiEndpoint);
  });

  test('local request-context lease revision invalidates the captured binding', () {
    var leaseRevision = 8;
    final source = BackupRunBindingSourceAdapter(() => _snapshot(localLeaseRevision: leaseRevision));
    final first = source.capture();

    leaseRevision = 9;

    expect(first, isNotNull);
    expect(source.isCurrent(first!), isFalse);
  });

  test('mixed session or probe identity is denied', () {
    final source = BackupRunBindingSourceAdapter(
      () => _snapshot(identity: ReachabilityIdentity(sessionEpoch: 2, probeGeneration: 9)),
    );

    expect(source.capture(), isNull);
  });

  test('transport revision change invalidates the captured binding', () {
    var transportRevision = 10;
    final source = BackupRunBindingSourceAdapter(() => _snapshot(transportRevision: transportRevision));
    final first = source.capture();

    transportRevision++;

    expect(first, isNotNull);
    expect(source.isCurrent(first!), isFalse);
  });

  test('torn authority snapshot is denied', () {
    final source = BackupRunBindingSourceAdapter(() => _snapshot(authorityRevisionAfter: 12));

    expect(source.capture(), isNull);
  });

  test('attached worker validates a persisted endpoint candidate against exact native evidence', () {
    const evidence = NativeServerAccessEvidence(
      apiEndpoint: null,
      canonicalOrigin: null,
      schemePolicy: EndpointSchemePolicy.httpsOnly,
      sessionEpoch: 7,
      generation: 9,
      confirmed: true,
      fenced: false,
    );
    final validEvidence = NativeServerAccessEvidence(
      apiEndpoint: null,
      canonicalOrigin: Uri.parse('https://photos.example'),
      schemePolicy: EndpointSchemePolicy.httpsOnly,
      sessionEpoch: 7,
      generation: 9,
      confirmed: true,
      fenced: false,
    );

    expect(
      resolveAttachedWorkerEndpoint(persistedEndpoint: 'https://photos.example/api', evidence: validEvidence),
      Uri.parse('https://photos.example/api'),
    );
    expect(
      resolveAttachedWorkerEndpoint(persistedEndpoint: 'https://attacker.example/api', evidence: validEvidence),
      isNull,
    );
    expect(resolveAttachedWorkerEndpoint(persistedEndpoint: 'https://photos.example/api', evidence: evidence), isNull);
  });
}

BackupBindingSnapshot _snapshot({
  int nativeGeneration = 4,
  int localLeaseRevision = 8,
  ReachabilityIdentity? identity,
  int transportRevision = 10,
  int authorityRevisionAfter = 11,
}) {
  final endpoint = Uri.parse('https://photos.example/api');
  return (
    userId: 'user-a',
    identity: identity ?? ReachabilityIdentity(sessionEpoch: 2, probeGeneration: 3),
    reachability: ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 2,
      probeGeneration: 3,
      confirmedEndpoint: endpoint,
      serverAccess: ConfirmedServerAccess(
        apiEndpoint: endpoint,
        canonicalOrigin: Uri.parse('https://photos.example'),
        schemePolicy: EndpointSchemePolicy.httpsOnly,
        nativeContextGeneration: nativeGeneration,
        confirmed: true,
        fenced: false,
      ),
    ),
    localLeaseRevision: localLeaseRevision,
    transportRevision: transportRevision,
    authorityRevisionBefore: 11,
    authorityRevisionAfter: authorityRevisionAfter,
  );
}
