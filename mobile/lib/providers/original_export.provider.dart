import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/local_original_export.interface.dart';
import 'package:immich_mobile/domain/interfaces/remote_original_export.interface.dart';
import 'package:immich_mobile/domain/models/original_export.model.dart';
import 'package:immich_mobile/domain/models/server_reachability.model.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/native_original_export_adapter.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/original_export_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/original_export/owned_temporary_file_lease.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/remote_authentication.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:immich_mobile/repositories/auth.repository.dart';
import 'package:immich_mobile/services/network.service.dart';
import 'package:logging/logging.dart';
import 'package:path_provider/path_provider.dart';

final _log = Logger('OriginalExportProvider');

final originalExportHostApiProvider = Provider<OriginalExportHostApi>((ref) {
  return PigeonOriginalExportHostApi(api: ref.read(originalExportApiProvider));
});

final originalExportSessionSnapshotReaderProvider = Provider<OriginalExportSessionSnapshot Function()>((ref) {
  return () {
    final reachability = ref.read(serverReachabilityStateProvider);
    final currentIdentity = ref.read(sessionEpochControllerProvider).current;
    final proof = ref.read(confirmedServerAccessProvider).read();
    final sessionActive =
        ref.read(remoteAuthenticationPhaseProvider) == RemoteAuthenticationPhase.authenticated &&
        reachability.sessionEpoch == currentIdentity.sessionEpoch;
    final binding =
        sessionActive &&
            reachability.phase == ReachabilityPhase.online &&
            proof != null &&
            proof.isCurrent &&
            proof.apiEndpoint == reachability.confirmedEndpoint
        ? OriginalExportContextBinding(
            sessionEpoch: reachability.sessionEpoch,
            expectedContextGeneration: proof.nativeContextGeneration,
            apiEndpoint: proof.apiEndpoint,
            exactOrigin: proof.canonicalOrigin,
            schemePolicy: proof.schemePolicy,
          )
        : null;
    return OriginalExportSessionSnapshot(reachability: reachability, sessionActive: sessionActive, binding: binding);
  };
});

final nativeOriginalExportAdapterProvider = Provider<NativeOriginalExportAdapter>((ref) {
  final readSnapshot = ref.read(originalExportSessionSnapshotReaderProvider);

  final adapter = NativeOriginalExportAdapter(
    api: ref.read(originalExportHostApiProvider),
    readTransportAvailability: () => ref.read(transportAvailabilityProvider),
    readSessionSnapshot: readSnapshot,
    verifyRegisteredLocalHttpRetryLease: (initiating, candidate) async {
      if (ref.read(transportAvailabilityProvider) != TransportAvailability.available ||
          readSnapshot().binding != candidate) {
        return false;
      }
      final preferredWifi = ref.read(authRepositoryProvider).getPreferredWifiName();
      if (preferredWifi == null || preferredWifi.isEmpty) {
        return false;
      }
      final currentWifi = await ref.read(networkServiceProvider).getWifiName();
      return currentWifi == preferredWifi && readSnapshot().binding == candidate;
    },
    reportFailure: (event) => _log.warning(
      'Original export failure '
      'phase=${event.phase.name} '
      'errorCode=${event.errorCode.name} '
      'attempt=${event.attempt} '
      'sessionRelation=${event.sessionRelation.name}',
    ),
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
