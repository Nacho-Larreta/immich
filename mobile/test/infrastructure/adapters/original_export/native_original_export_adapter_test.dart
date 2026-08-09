import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart' as domain;
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/native_original_export_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/original_export_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/owned_temporary_file_lease.dart';
import 'package:immich_mobile/platform/original_export_api.g.dart' as pigeon;

void main() {
  group('NativeOriginalExportAdapter local policy', () {
    for (final availability in TransportAvailability.values) {
      test('clamps allowICloud for $availability', () async {
        final harness = _Harness(availability: availability);
        harness.host.localResult = pigeon.OriginalExportResult(
          path: null,
          error: pigeon.OriginalExportErrorCode.mediaNotLocal,
        );

        await harness.adapter.local
            .export(
              domain.LocalOriginalExportRequest(
                assetId: 'local-1',
                suggestedFilename: 'photo.jpg',
                policy: domain.LocalOriginalExportPolicy.allowICloud,
              ),
            )
            .result;

        expect(
          harness.host.localRequests.single.policy,
          availability == TransportAvailability.available
              ? pigeon.OriginalExportPolicy.allowICloud
              : pigeon.OriginalExportPolicy.localOnly,
        );
      });
    }
  });

  group('NativeOriginalExportAdapter remote authorization', () {
    test('offline or inactive session performs zero native work', () async {
      for (final snapshot in [
        _snapshot(ReachabilityPhase.offline),
        _snapshot(ReachabilityPhase.online, sessionActive: false),
      ]) {
        final harness = _Harness(snapshot: snapshot);

        final result = await harness.adapter.remote.export(_remoteRequest()).result;

        expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.serverUnavailable));
        expect(harness.host.remoteRequests, isEmpty);
      }
    });

    test('rejects wrong origin and accepts the confirmed endpoint path', () async {
      final harness = _Harness();
      final denied = domain.RemoteOriginalExportRequest(
        resource: Uri.parse('https://evil.test/api/assets/1/original'),
        suggestedFilename: 'photo.jpg',
      );

      await harness.adapter.remote.export(denied).result;
      expect(harness.host.remoteRequests, isEmpty);

      harness.host.remoteResult = pigeon.OriginalExportResult(
        path: null,
        error: pigeon.OriginalExportErrorCode.unauthorized,
      );
      final result = await harness.adapter.remote.export(_remoteRequest()).result;
      expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.unauthorized));
      expect(harness.host.remoteRequests, hasLength(1));
    });

    test('maps every typed native error without leaking platform details', () async {
      for (final error in pigeon.OriginalExportErrorCode.values) {
        final harness = _Harness();
        harness.host.remoteResult = pigeon.OriginalExportResult(path: null, error: error);

        final result = await harness.adapter.remote.export(_remoteRequest()).result;

        expect(result, domain.OriginalExportResult.failure(domain.OriginalExportError.values[error.index]));
      }
    });
  });

  test('cancel waits for both native barrier and terminal result exactly once', () async {
    final host = _Host()
      ..controlledLocal = Completer()
      ..cancelBarrier = Completer();
    final harness = _Harness(host: host);
    final operation = harness.adapter.local.export(
      domain.LocalOriginalExportRequest(
        assetId: 'local-1',
        suggestedFilename: 'photo.jpg',
        policy: domain.LocalOriginalExportPolicy.localOnly,
      ),
    );
    await pumpEventQueue();

    final firstCancel = operation.cancel();
    final secondCancel = operation.cancel();
    var cancelCompleted = false;
    unawaited(firstCancel.then((_) => cancelCompleted = true));
    await pumpEventQueue();
    expect(cancelCompleted, isFalse);

    host.cancelBarrier!.complete();
    await pumpEventQueue();
    expect(cancelCompleted, isFalse);

    host.controlledLocal!.complete(
      pigeon.OriginalExportResult(path: null, leaseToken: null, error: pigeon.OriginalExportErrorCode.cancelled),
    );
    await Future.wait([firstCancel, secondCancel]);

    expect(host.cancelledRequestIds, hasLength(1));
    expect(await operation.result, const domain.OriginalExportResult.failure(domain.OriginalExportError.cancelled));
  });

  test('malformed XOR releases the native lease and fails closed', () async {
    final harness = _Harness();
    harness.host.localResult = pigeon.OriginalExportResult(
      path: '/tmp/file',
      leaseToken: 'malformed-token',
      error: pigeon.OriginalExportErrorCode.writeFailed,
    );

    final result = await harness.adapter.local
        .export(
          domain.LocalOriginalExportRequest(
            assetId: 'local-1',
            suggestedFilename: 'photo.jpg',
            policy: domain.LocalOriginalExportPolicy.localOnly,
          ),
        )
        .result;

    expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.writeFailed));
    expect(harness.host.releasedLeaseTokens, ['malformed-token']);
  });

  test('failed path adoption releases the native token and returns storageUnavailable', () async {
    final harness = _Harness(rejectLease: true);
    harness.host.localResult = pigeon.OriginalExportResult(
      path: '/outside/immich-share-bad/photo.jpg',
      leaseToken: 'outside-token',
      error: null,
    );

    final result = await harness.adapter.local
        .export(
          domain.LocalOriginalExportRequest(
            assetId: 'local-1',
            suggestedFilename: 'photo.jpg',
            policy: domain.LocalOriginalExportPolicy.localOnly,
          ),
        )
        .result;

    expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.storageUnavailable));
    expect(harness.host.releasedLeaseTokens, ['outside-token']);
  });

  test('cancelAll waits for its native barrier and every active terminal result', () async {
    final host = _Host()
      ..controlledLocal = Completer()
      ..cancelAllBarrier = Completer();
    final harness = _Harness(host: host);
    final operation = harness.adapter.local.export(
      domain.LocalOriginalExportRequest(
        assetId: 'local-1',
        suggestedFilename: 'photo.jpg',
        policy: domain.LocalOriginalExportPolicy.localOnly,
      ),
    );
    final cancellation = harness.adapter.cancelAll();
    var completed = false;
    unawaited(cancellation.then((_) => completed = true));
    await pumpEventQueue();
    expect(completed, isFalse);

    host.cancelAllBarrier!.complete();
    await pumpEventQueue();
    expect(completed, isFalse);
    host.controlledLocal!.complete(
      pigeon.OriginalExportResult(path: null, leaseToken: null, error: pigeon.OriginalExportErrorCode.cancelled),
    );

    await cancellation;
    expect(await operation.result, const domain.OriginalExportResult.failure(domain.OriginalExportError.cancelled));
  });

  test('outside-root and symlink results are rejected and released natively', () async {
    final root = await Directory.systemTemp.createTemp('original-export-adoption-');
    addTearDown(() => root.delete(recursive: true));
    final outsideDirectory = await Directory('${root.parent.path}/immich-share-outside-adoption').create();
    final outsideFile = await File('${outsideDirectory.path}/photo.jpg').writeAsString('outside');
    addTearDown(() async {
      if (await outsideDirectory.exists()) await outsideDirectory.delete(recursive: true);
    });
    final ownedDirectory = await Directory('${root.path}/immich-share-link').create();
    final target = await File('${ownedDirectory.path}/target.jpg').writeAsString('target');
    final link = await Link('${ownedDirectory.path}/photo.jpg').create(target.path);

    for (final entry in [(outsideFile.path, 'outside-token'), (link.path, 'link-token')]) {
      final harness = _Harness(
        leaseFactory: (path, token, release) => OwnedTemporaryFileLease.adopt(
          path: path,
          leaseToken: token,
          temporaryRoot: root.path,
          releaseNativeLease: release,
        ),
      );
      harness.host.localResult = pigeon.OriginalExportResult(path: entry.$1, leaseToken: entry.$2, error: null);

      final result = await harness.adapter.local
          .export(
            domain.LocalOriginalExportRequest(
              assetId: 'local-1',
              suggestedFilename: 'photo.jpg',
              policy: domain.LocalOriginalExportPolicy.localOnly,
            ),
          )
          .result;

      expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.storageUnavailable));
      expect(harness.host.releasedLeaseTokens, [entry.$2]);
    }
  });
}

domain.RemoteOriginalExportRequest _remoteRequest() {
  return domain.RemoteOriginalExportRequest(
    resource: Uri.parse('https://photos.test/api/assets/asset-1/original'),
    suggestedFilename: 'photo.jpg',
  );
}

OriginalExportSessionSnapshot _snapshot(ReachabilityPhase phase, {bool sessionActive = true}) {
  return OriginalExportSessionSnapshot(
    reachability: ReachabilityState(
      phase: phase,
      sessionEpoch: 1,
      probeGeneration: 1,
      confirmedEndpoint: phase == ReachabilityPhase.online ? Uri.parse('https://photos.test/api') : null,
    ),
    sessionActive: sessionActive,
  );
}

final class _Harness {
  _Harness({
    _Host? host,
    this.availability = TransportAvailability.available,
    OriginalExportSessionSnapshot? snapshot,
    _Lease? lease,
    this.rejectLease = false,
    TemporaryFileLeaseFactory? leaseFactory,
  }) : host = host ?? _Host(),
       snapshot = snapshot ?? _snapshot(ReachabilityPhase.online),
       lease = lease ?? _Lease('/tmp/immich-share-test/photo.jpg') {
    adapter = NativeOriginalExportAdapter(
      api: this.host,
      readTransportAvailability: () => availability,
      readSessionSnapshot: () => this.snapshot,
      leaseFactory:
          leaseFactory ??
          (_, _, _) async {
            if (rejectLease) {
              throw const FileSystemException('invalid lease');
            }
            return this.lease;
          },
      registerFlutterApi: (_) {},
    );
  }

  final _Host host;
  final TransportAvailability availability;
  final OriginalExportSessionSnapshot snapshot;
  final _Lease lease;
  final bool rejectLease;
  late final NativeOriginalExportAdapter adapter;
}

final class _Host implements OriginalExportHostApi {
  pigeon.OriginalExportResult localResult = pigeon.OriginalExportResult(
    path: null,
    error: pigeon.OriginalExportErrorCode.assetMissing,
  );
  pigeon.OriginalExportResult remoteResult = pigeon.OriginalExportResult(
    path: null,
    error: pigeon.OriginalExportErrorCode.serverUnavailable,
  );
  Completer<pigeon.OriginalExportResult>? controlledLocal;
  Completer<void>? cancelBarrier;
  Completer<void>? cancelAllBarrier;
  final List<pigeon.LocalOriginalExportRequest> localRequests = [];
  final List<pigeon.RemoteOriginalExportRequest> remoteRequests = [];
  final List<int> cancelledRequestIds = [];
  final List<String> releasedLeaseTokens = [];

  @override
  Future<pigeon.OriginalExportResult> exportLocal(pigeon.LocalOriginalExportRequest request) {
    localRequests.add(request);
    return controlledLocal?.future ?? Future.value(localResult);
  }

  @override
  Future<pigeon.OriginalExportResult> exportRemote(pigeon.RemoteOriginalExportRequest request) {
    remoteRequests.add(request);
    return Future.value(remoteResult);
  }

  @override
  Future<void> cancelRequest(int requestId) async {
    cancelledRequestIds.add(requestId);
    await cancelBarrier?.future;
  }

  @override
  Future<void> cancelAll() async => cancelAllBarrier?.future;

  @override
  Future<void> dispose() async {}

  @override
  Future<pigeon.OriginalExportReleaseResult> releaseLease(String leaseToken) async {
    releasedLeaseTokens.add(leaseToken);
    return pigeon.OriginalExportReleaseResult(error: null);
  }
}

final class _Lease extends TemporaryFileLease {
  _Lease(String path) : super(path: path, ownership: TemporaryFileOwnership.caller);

  int releaseCount = 0;

  @override
  Future<void> releaseResource() async => releaseCount++;
}
