import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/models/store.model.dart';
import 'package:immich_mobile/entities/store.entity.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/native_original_export_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/original_export_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/owned_temporary_file_lease.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('OriginalExportProvider');

final originalExportHostApiProvider = Provider<OriginalExportHostApi>((ref) {
  return PigeonOriginalExportHostApi(api: ref.read(originalExportApiProvider));
});

final nativeOriginalExportAdapterProvider = Provider<NativeOriginalExportAdapter>((ref) {
  final adapter = NativeOriginalExportAdapter(
    api: ref.read(originalExportHostApiProvider),
    readTransportAvailability: () => ref.read(transportAvailabilityProvider),
    readSessionSnapshot: () {
      final reachability = ref.read(serverReachabilityStateProvider);
      final currentIdentity = ref.read(sessionEpochControllerProvider).current;
      final accessToken = Store.tryGet(StoreKey.accessToken);
      final user = Store.tryGet(StoreKey.currentUser);
      return OriginalExportSessionSnapshot(
        reachability: reachability,
        sessionActive:
            reachability.sessionEpoch == currentIdentity.sessionEpoch &&
            accessToken != null &&
            accessToken.isNotEmpty &&
            user != null,
      );
    },
    leaseFactory: (path, leaseToken, releaseNativeLease) async {
      final temporaryRoot = await getTemporaryDirectory();
      return OwnedTemporaryFileLease.adopt(
        path: path,
        leaseToken: leaseToken,
        temporaryRoot: temporaryRoot.path,
        releaseNativeLease: releaseNativeLease,
      );
    },
  );
  ref.onDispose(() {
    unawaited(
      adapter.dispose().catchError((Object error, StackTrace stackTrace) {
        _log.warning('Unable to dispose original export resources', error, stackTrace);
      }),
    );
  });
  return adapter;
});

final localOriginalExportProvider = Provider<LocalOriginalExportPort>((ref) {
  return ref.read(nativeOriginalExportAdapterProvider).local;
});

final remoteOriginalExportProvider = Provider<RemoteOriginalExportPort>((ref) {
  return ref.read(nativeOriginalExportAdapterProvider).remote;
});

final remoteOriginalUriBuilderProvider = Provider<Uri? Function(String assetId, {required bool edited})>((ref) {
  return (assetId, {required edited}) {
    final endpoint = ref.read(serverReachabilityStateProvider).confirmedEndpoint;
    if (endpoint == null) {
      return null;
    }
    final endpointSegments = endpoint.pathSegments.where((segment) => segment.isNotEmpty);
    return endpoint.replace(
      pathSegments: [...endpointSegments, 'assets', assetId, 'original'],
      queryParameters: {'edited': edited.toString()},
    );
  };
});
