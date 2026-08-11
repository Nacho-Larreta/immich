import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/services.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/utils/worker_termination_safety.dart';

void main() {
  test('attached cleanup drains network before releasing non-network resources', () async {
    final events = <String>[];

    await drainNetworkBeforeRelease(
      drainNetwork: () async => events.add('network'),
      releaseResources: () async => events.add('resources'),
      logCode: events.add,
    );

    expect(events, ['network', 'resources']);
  });

  test('drain failure is unsafe and logs only an allowlisted code', () async {
    const secret = 'server-token-must-not-appear';
    final logs = <String>[];
    var resourcesReleased = false;

    await expectLater(
      drainNetworkBeforeRelease(
        drainNetwork: () async => throw StateError(secret),
        releaseResources: () async => resourcesReleased = true,
        logCode: logs.add,
      ),
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', unsafeWorkerTerminationCode)),
    );

    expect(resourcesReleased, isFalse);
    expect(logs, [networkDrainFailureLogCode]);
    expect(logs.join(), isNot(contains(secret)));
  });

  test('delayed unsafe worker disposal wins before ordinary cleanup starts', () async {
    final workerDisposal = Completer<void>();
    var ordinaryCleanupStarted = false;

    final cleanup = disposeWorkersBeforeOrdinaryCleanup(
      disposeWorkers: () => workerDisposal.future,
      cleanupOrdinaryResources: () async {
        ordinaryCleanupStarted = true;
        throw StateError('ordinary-cleanup-failed-first');
      },
    );
    final unsafeResult = expectLater(
      cleanup,
      throwsA(isA<PlatformException>().having((error) => error.code, 'code', unsafeWorkerTerminationCode)),
    );

    await Future<void>.delayed(Duration.zero);
    expect(ordinaryCleanupStarted, isFalse);

    workerDisposal.completeError(PlatformException(code: unsafeWorkerTerminationCode));
    await unsafeResult;
    expect(ordinaryCleanupStarted, isFalse);
  });
}
