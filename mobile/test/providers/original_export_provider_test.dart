import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/original_export_host_api.dart';
import 'package:immich_mobile/platform/original_export_api.g.dart' as pigeon;
import 'package:immich_mobile/providers/original_export.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('keeps one app-scoped adapter and sanitizes container disposal', () async {
    final host = _Host();
    final container = ProviderContainer(overrides: [originalExportHostApiProvider.overrideWithValue(host)]);

    final local = container.read(localOriginalExportProvider);
    final remote = container.read(remoteOriginalExportProvider);
    expect(identical(local, container.read(localOriginalExportProvider)), isTrue);
    expect(identical(remote, container.read(remoteOriginalExportProvider)), isTrue);

    container.dispose();
    await pumpEventQueue();
    expect(host.cancelAllCount, 1);
    expect(host.disposeCount, 1);
  });

  test('builds a remote original URL only from the confirmed endpoint snapshot', () {
    final online = ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 2,
      probeGeneration: 3,
      confirmedEndpoint: Uri.parse('https://photos.test/custom/api'),
    );
    final onlineContainer = ProviderContainer(overrides: [serverReachabilityStateProvider.overrideWith((_) => online)]);
    addTearDown(onlineContainer.dispose);

    expect(
      onlineContainer.read(remoteOriginalUriBuilderProvider)('asset/id', edited: true),
      Uri.parse('https://photos.test/custom/api/assets/asset%2Fid/original?edited=true'),
    );

    final offlineContainer = ProviderContainer(
      overrides: [
        serverReachabilityStateProvider.overrideWith(
          (_) => ReachabilityState(phase: ReachabilityPhase.offline, sessionEpoch: 2, probeGeneration: 3),
        ),
      ],
    );
    addTearDown(offlineContainer.dispose);
    expect(offlineContainer.read(remoteOriginalUriBuilderProvider)('asset', edited: false), isNull);
  });
}

final class _Host implements OriginalExportHostApi {
  int cancelAllCount = 0;
  int disposeCount = 0;

  @override
  Future<pigeon.OriginalExportResult> exportLocal(pigeon.LocalOriginalExportRequest request) {
    return Future.value(pigeon.OriginalExportResult(path: null, error: pigeon.OriginalExportErrorCode.assetMissing));
  }

  @override
  Future<pigeon.OriginalExportResult> exportRemote(pigeon.RemoteOriginalExportRequest request) {
    return Future.value(
      pigeon.OriginalExportResult(path: null, error: pigeon.OriginalExportErrorCode.serverUnavailable),
    );
  }

  @override
  Future<void> cancelRequest(int requestId) async {}

  @override
  Future<void> cancelAll() async => cancelAllCount++;

  @override
  Future<void> dispose() async => disposeCount++;

  @override
  Future<pigeon.OriginalExportReleaseResult> releaseLease(String leaseToken) async {
    return pigeon.OriginalExportReleaseResult(error: null);
  }
}
