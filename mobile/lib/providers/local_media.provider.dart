import 'dart:async';

import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/local_media.interface.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/local_media_host_api.dart';
import 'package:immich_mobile/infrastructure/adapters/local_media/native_local_media_adapter.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/providers/infrastructure/platform.provider.dart';
import 'package:immich_mobile/providers/server_reachability.provider.dart';
import 'package:logging/logging.dart';

final _log = Logger('LocalMediaProvider');

final localMediaHostApiProvider = Provider<LocalMediaHostApi>((ref) {
  return PigeonLocalMediaHostApi(api: ref.read(localImageApiProvider));
});

final localMediaFlutterApiRegistrationProvider = Provider<LocalMediaFlutterApiRegistration>((_) {
  return LocalImageFlutterApi.setUp;
});

final nativeLocalMediaAdapterProvider = Provider<NativeLocalMediaAdapter>((ref) {
  final adapter = NativeLocalMediaAdapter(
    api: ref.read(localMediaHostApiProvider),
    readTransportAvailability: () => ref.read(transportAvailabilityProvider),
    registerFlutterApi: ref.read(localMediaFlutterApiRegistrationProvider),
  );
  ref.onDispose(() {
    unawaited(
      adapter.dispose().catchError((Object _) {
        _log.warning('Unable to dispose local media resources');
      }),
    );
  });
  return adapter;
});

final localMediaProvider = Provider<LocalMediaPort<OwnedLocalMediaPayload>>((ref) {
  return ref.read(nativeLocalMediaAdapterProvider);
});
