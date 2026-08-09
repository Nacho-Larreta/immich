import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/models/offline_result.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/domain/services/session_epoch_controller.dart';
import 'package:immich_mobile/infrastructure/adapters/reconciliation/server_reconciliation_adapter.dart';

void main() {
  test('refreshes websocket then syncs, hashes, albums and backup in order', () async {
    final harness = _Harness(syncAlbums: true, backupEnabled: true, userId: 'user-1');

    final result = await harness.adapter.reconcile(harness.request).result;

    expect(result, const OfflineResult.success(OperationCompletion.completed));
    expect(harness.events, [
      'websocket.disconnect',
      'websocket.connect',
      'syncRemote',
      'hashAssets',
      'syncLinkedAlbums',
      'backup:user-1',
    ]);
  });

  test('does not hash, sync albums or backup when remote sync fails', () async {
    final harness = _Harness(syncSucceeded: false, syncAlbums: true, backupEnabled: true, userId: 'user-1');

    expect(
      await harness.adapter.reconcile(harness.request).result,
      const OfflineResult<OperationCompletion>.failure(OfflineErrorCode.serverUnavailable),
    );
    expect(harness.events, ['websocket.disconnect', 'websocket.connect', 'syncRemote']);
  });

  test('cancellation stops every owned background collaborator and waits active work', () async {
    final syncGate = Completer<bool>();
    final harness = _Harness(syncRemote: () => syncGate.future);
    final operation = harness.adapter.reconcile(harness.request);
    await pumpEventQueue();

    final cancellation = operation.cancel();
    await pumpEventQueue();

    expect(
      harness.events,
      containsAllInOrder(['syncRemote', 'cancelRemote', 'cancelLocal', 'backup.stop', 'websocket.disconnect']),
    );
    var cancellationCompleted = false;
    unawaited(cancellation.then((_) => cancellationCompleted = true));
    await pumpEventQueue();
    expect(cancellationCompleted, isFalse);

    syncGate.complete(true);
    await cancellation;
    expect(await operation.result, const OfflineResult<OperationCompletion>.failure(OfflineErrorCode.cancelled));
    expect(harness.events, isNot(contains('hashAssets')));
  });

  test('stale epoch after remote sync prevents hashing and backup', () async {
    late _Harness harness;
    harness = _Harness(
      syncRemote: () async {
        harness.epochs.invalidateSession();
        return true;
      },
      backupEnabled: true,
      userId: 'user-1',
    );

    expect(
      await harness.adapter.reconcile(harness.request).result,
      const OfflineResult<OperationCompletion>.failure(OfflineErrorCode.cancelled),
    );
    expect(harness.events, isNot(contains('hashAssets')));
  });
}

final class _Harness {
  _Harness({
    bool syncSucceeded = true,
    Future<bool> Function()? syncRemote,
    this.syncAlbums = false,
    this.backupEnabled = false,
    this.userId,
  }) : _syncRemote = syncRemote ?? (() async => syncSucceeded) {
    adapter = ServerReconciliationAdapter(
      epochs: epochs,
      readSnapshot: () => ReconciliationSnapshot(syncAlbums: syncAlbums, backupEnabled: backupEnabled, userId: userId),
      disconnectWebsocket: () => events.add('websocket.disconnect'),
      connectWebsocket: () => events.add('websocket.connect'),
      syncRemote: () async {
        events.add('syncRemote');
        return _syncRemote();
      },
      hashAssets: () async => events.add('hashAssets'),
      syncLinkedAlbums: () async => events.add('syncLinkedAlbums'),
      startBackup: (userId) async => events.add('backup:$userId'),
      stopBackup: () => events.add('backup.stop'),
      cancelRemoteWork: () async => events.add('cancelRemote'),
      cancelLocalWork: () async => events.add('cancelLocal'),
    );
  }

  final epochs = SessionEpochController();
  final events = <String>[];
  final bool syncAlbums;
  final bool backupEnabled;
  final String? userId;
  final Future<bool> Function() _syncRemote;
  late final ServerReconciliationAdapter adapter;

  ReconciliationRequest get request {
    final identity = epochs.current;
    return ReconciliationRequest(
      sessionEpoch: identity.sessionEpoch,
      probeGeneration: identity.probeGeneration,
      confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
    );
  }
}
