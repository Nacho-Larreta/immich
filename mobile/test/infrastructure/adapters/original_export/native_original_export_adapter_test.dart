import 'dart:async';
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/domain/interfaces/temporary_file_lease.interface.dart';
import 'package:immich_mobile/domain/models/endpoint_probe.model.dart';
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

    test('retries stale local HTTP exactly once with a new request id and current WiFi lease', () async {
      final initial = _localHttpSnapshot(generation: 11);
      final harness = _Harness(snapshot: initial, retryLeaseValid: true);
      harness.host.remoteResults.addAll([
        pigeon.OriginalExportResult(error: pigeon.OriginalExportErrorCode.staleContext),
        pigeon.OriginalExportResult(path: '/tmp/share/photo.jpg', leaseToken: 'lease-2'),
      ]);
      harness.host.onRemoteRequest = (_) => harness.snapshot = _localHttpSnapshot(generation: 12);

      final result = await harness.adapter.remote.export(_remoteHttpRequest()).result;

      expect(result, isA<domain.OriginalExportSuccess>());
      expect(harness.host.remoteRequests.map((request) => request.requestId).toSet(), hasLength(2));
      expect(harness.host.remoteRequests.map((request) => request.expectedContextGeneration), [11, 12]);
      expect(harness.retryLeaseChecks, 1);
    });

    test('malformed stale result releases its token and never retries', () async {
      final harness = _Harness(snapshot: _localHttpSnapshot(generation: 11), retryLeaseValid: true);
      harness.host.remoteResult = pigeon.OriginalExportResult(
        path: '/tmp/share/untrusted.jpg',
        leaseToken: 'malformed-stale-token',
        error: pigeon.OriginalExportErrorCode.staleContext,
      );
      harness.host.onRemoteRequest = (_) => harness.snapshot = _localHttpSnapshot(generation: 12);

      final result = await harness.adapter.remote.export(_remoteHttpRequest()).result;

      expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.writeFailed));
      expect(harness.host.remoteRequests, hasLength(1));
      expect(harness.retryLeaseChecks, 0);
      expect(harness.host.releasedLeaseTokens, ['malformed-stale-token']);
    });

    test('transport loss during WiFi verification prevents stale retry', () async {
      final retryGate = Completer<bool>();
      final harness = _Harness(
        snapshot: _localHttpSnapshot(generation: 11),
        retryLeaseVerifier: (_, _) => retryGate.future,
      );
      harness.host.remoteResult = pigeon.OriginalExportResult(error: pigeon.OriginalExportErrorCode.staleContext);
      harness.host.onRemoteRequest = (_) => harness.snapshot = _localHttpSnapshot(generation: 12);

      final operation = harness.adapter.remote.export(_remoteHttpRequest());
      await pumpEventQueue();
      harness.availability = TransportAvailability.unavailable;
      retryGate.complete(true);

      expect(
        await operation.result,
        const domain.OriginalExportResult.failure(domain.OriginalExportError.staleContext),
      );
      expect(harness.host.remoteRequests, hasLength(1));
    });

    test('never retries stale HTTPS and returns the typed terminal', () async {
      final harness = _Harness();
      harness.host.remoteResult = pigeon.OriginalExportResult(error: pigeon.OriginalExportErrorCode.staleContext);

      final result = await harness.adapter.remote.export(_remoteRequest()).result;

      expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.staleContext));
      expect(harness.host.remoteRequests, hasLength(1));
      expect(harness.retryLeaseChecks, 0);
      expect(harness.failures, hasLength(1));
      expect(harness.failures.single.phase, domain.OriginalExportFailurePhase.native);
      expect(harness.failures.single.errorCode, domain.OriginalExportError.staleContext);
      expect(harness.failures.single.attempt, 1);
      expect(harness.failures.single.sessionRelation, domain.OriginalExportSessionRelation.current);
    });

    test('a second stale local HTTP response is terminal and never loops', () async {
      final harness = _Harness(snapshot: _localHttpSnapshot(generation: 11), retryLeaseValid: true);
      harness.host.remoteResults.addAll([
        pigeon.OriginalExportResult(error: pigeon.OriginalExportErrorCode.staleContext),
        pigeon.OriginalExportResult(error: pigeon.OriginalExportErrorCode.staleContext),
      ]);
      harness.host.onRemoteRequest = (_) => harness.snapshot = _localHttpSnapshot(generation: 12);

      final result = await harness.adapter.remote.export(_remoteHttpRequest()).result;

      expect(result, const domain.OriginalExportResult.failure(domain.OriginalExportError.staleContext));
      expect(harness.host.remoteRequests, hasLength(2));
    });

    test('cancel between stale terminal and retry creates no second native request', () async {
      final retryGate = Completer<bool>();
      final harness = _Harness(
        snapshot: _localHttpSnapshot(generation: 11),
        retryLeaseVerifier: (_, _) => retryGate.future,
      );
      harness.host.remoteResult = pigeon.OriginalExportResult(error: pigeon.OriginalExportErrorCode.staleContext);
      harness.host.onRemoteRequest = (_) => harness.snapshot = _localHttpSnapshot(generation: 12);

      final operation = harness.adapter.remote.export(_remoteHttpRequest());
      await pumpEventQueue();
      await operation.cancel();
      retryGate.complete(true);

      expect(await operation.result, const domain.OriginalExportResult.failure(domain.OriginalExportError.cancelled));
      expect(harness.host.remoteRequests, hasLength(1));
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
    expect(harness.failures, hasLength(1));
    expect(harness.failures.single.phase, domain.OriginalExportFailurePhase.adoption);
    expect(harness.failures.single.errorCode, domain.OriginalExportError.storageUnavailable);
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

domain.RemoteOriginalExportRequest _remoteHttpRequest() {
  return domain.RemoteOriginalExportRequest(
    resource: Uri.parse('http://photos.test:2283/api/assets/asset-1/original'),
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
    binding: phase == ReachabilityPhase.online ? _binding() : null,
  );
}

domain.OriginalExportContextBinding _binding({int generation = 7}) {
  return domain.OriginalExportContextBinding(
    sessionEpoch: 1,
    expectedContextGeneration: generation,
    apiEndpoint: Uri.parse('https://photos.test/api'),
    exactOrigin: Uri.parse('https://photos.test'),
    schemePolicy: EndpointSchemePolicy.httpsOnly,
  );
}

OriginalExportSessionSnapshot _localHttpSnapshot({required int generation}) {
  final endpoint = Uri.parse('http://photos.test:2283/api');
  return OriginalExportSessionSnapshot(
    reachability: ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 1,
      probeGeneration: generation,
      confirmedEndpoint: endpoint,
    ),
    sessionActive: true,
    binding: domain.OriginalExportContextBinding(
      sessionEpoch: 1,
      expectedContextGeneration: generation,
      apiEndpoint: endpoint,
      exactOrigin: Uri.parse('http://photos.test:2283'),
      schemePolicy: EndpointSchemePolicy.registeredLocalHttp,
    ),
  );
}

final class _Harness {
  _Harness({
    _Host? host,
    this.availability = TransportAvailability.available,
    OriginalExportSessionSnapshot? snapshot,
    this.retryLeaseValid = false,
    RegisteredLocalHttpRetryLeaseVerifier? retryLeaseVerifier,
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
      verifyRegisteredLocalHttpRetryLease: (initiating, candidate) async {
        retryLeaseChecks++;
        return retryLeaseVerifier?.call(initiating, candidate) ?? retryLeaseValid;
      },
      reportFailure: failures.add,
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
  TransportAvailability availability;
  OriginalExportSessionSnapshot snapshot;
  final bool retryLeaseValid;
  int retryLeaseChecks = 0;
  final List<domain.OriginalExportFailureEvent> failures = [];
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
  final List<pigeon.OriginalExportResult> remoteResults = [];
  void Function(pigeon.RemoteOriginalExportRequest request)? onRemoteRequest;
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
    onRemoteRequest?.call(request);
    return Future.value(remoteResults.isEmpty ? remoteResult : remoteResults.removeAt(0));
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
