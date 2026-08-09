import 'package:flutter_test/flutter_test.dart';
import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/models/media_request.model.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/remote_media/remote_media_host_api.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';
import 'package:immich_mobile/providers/remote_media.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';

void main() {
  test('reachability and epoch transitions rebuild the factory while preserving the app-scoped port', () async {
    final host = _Host();
    final container = ProviderContainer(
      overrides: [
        remoteMediaHostApiProvider.overrideWithValue(host),
        remoteMediaEndpointSnapshotProvider.overrideWithValue(
          RemoteMediaEndpointSnapshot(Uri.parse('https://photos.example.test/api')),
        ),
      ],
    );
    addTearDown(container.dispose);

    final unknown = container.read(remoteImageProviderFactoryProvider);
    expect(unknown.access.policy, RemoteMediaPolicy.cacheOnly);
    expect(unknown.access.sessionEpoch, 0);

    container.read(serverReachabilityStateProvider.notifier).state = ReachabilityState(
      phase: ReachabilityPhase.online,
      sessionEpoch: 0,
      probeGeneration: 1,
      confirmedEndpoint: Uri.parse('https://photos.example.test/api'),
    );
    final online = container.read(remoteImageProviderFactoryProvider);
    expect(online.access.policy, RemoteMediaPolicy.cacheThenNetwork);
    expect(identical(unknown.media, online.media), isTrue);

    container.read(serverReachabilityStateProvider.notifier).state = ReachabilityState(
      phase: ReachabilityPhase.offline,
      sessionEpoch: 1,
      probeGeneration: 0,
    );
    final relogged = container.read(remoteImageProviderFactoryProvider);
    expect(relogged.access.policy, RemoteMediaPolicy.cacheOnly);
    expect(relogged.access.sessionEpoch, 1);
    expect(identical(online.media, relogged.media), isTrue);
  });

  test('root disposal invokes terminal native cleanup once', () async {
    final host = _Host();
    final container = ProviderContainer(overrides: [remoteMediaHostApiProvider.overrideWithValue(host)]);
    container.read(remoteMediaProvider);

    container.dispose();
    await pumpEventQueue();

    expect(host.cancelAllCount, 1);
    expect(host.disposeCount, 1);
  });
}

final class _Host implements RemoteMediaHostApi {
  int cancelAllCount = 0;
  int disposeCount = 0;

  @override
  Future<RemoteImageResult> requestImage(RemoteImageRequest request) {
    throw StateError('unused');
  }

  @override
  Future<void> cancelRequest(int requestId) async {}

  @override
  Future<void> cancelAll() async => cancelAllCount++;

  @override
  Future<void> dispose() async => disposeCount++;
}
