import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/remote_media.interface.dart';
import 'package:immich_mobile/domain/models/remote_media_access.model.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/remote_media/native_remote_media_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/remote_media/remote_media_host_api.dart';
import 'package:immich_mobile/presentation/widgets/images/remote_image_provider.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('RemoteMediaProvider');

final remoteMediaHostApiProvider = Provider<RemoteMediaHostApi>((ref) {
  return PigeonRemoteMediaHostApi(api: ref.read(remoteImageApiProvider));
});

final nativeRemoteMediaAdapterProvider = Provider<NativeRemoteMediaAdapter>((ref) {
  final adapter = NativeRemoteMediaAdapter(api: ref.read(remoteMediaHostApiProvider));
  ref.onDispose(() {
    unawaited(
      adapter.dispose().catchError((Object _) {
        _log.warning('Unable to dispose remote media resources');
      }),
    );
  });
  return adapter;
});

final remoteMediaProvider = Provider<RemoteMediaPort<OwnedRemoteMediaPayload>>((ref) {
  return ref.read(nativeRemoteMediaAdapterProvider);
});

final remoteMediaAccessSnapshotProvider = Provider<RemoteMediaAccessSnapshot>((ref) {
  return mapRemoteMediaAccess(ref.watch(serverReachabilityStateProvider));
});

final remoteMediaEndpointSnapshotProvider = Provider<RemoteMediaEndpointSnapshot>((ref) {
  final state = ref.watch(serverReachabilityStateProvider);
  final endpoint = state.confirmedEndpoint ?? Uri.parse(Store.get(StoreKey.serverEndpoint));
  return RemoteMediaEndpointSnapshot(endpoint);
});

final remoteImageProviderFactoryProvider = Provider<RemoteImageProviderFactory>((ref) {
  return RemoteImageProviderFactory(
    media: ref.read(remoteMediaProvider),
    access: ref.watch(remoteMediaAccessSnapshotProvider),
    endpoint: ref.watch(remoteMediaEndpointSnapshotProvider),
  );
});
