import 'package:hooks_riverpod/hooks_riverpod.dart';
import 'package:immich_mobile/domain/interfaces/timeline_performance.interface.dart';
import 'package:immich_mobile/domain/services/background_worker.service.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/native_probe_http_transport.dart';
import 'package:immich_mobile/infrastructure/adapters/endpoint_probe/probe_http_transport.dart';
import 'package:immich_mobile/infrastructure/adapters/performance/native_timeline_performance_adapter.dart';
import 'package:immich_mobile/platform/background_worker_api.g.dart';
import 'package:immich_mobile/platform/background_worker_lock_api.g.dart';
import 'package:immich_mobile/platform/connectivity_api.g.dart';
import 'package:immich_mobile/platform/native_sync_api.g.dart';
import 'package:immich_mobile/platform/local_image_api.g.dart';
import 'package:immich_mobile/platform/network_api.g.dart';
import 'package:immich_mobile/platform/original_export_api.g.dart';
import 'package:immich_mobile/platform/performance_api.g.dart';
import 'package:immich_mobile/platform/remote_image_api.g.dart';

final backgroundWorkerFgServiceProvider = Provider((_) => BackgroundWorkerFgService(BackgroundWorkerFgHostApi()));

final backgroundWorkerLockServiceProvider = Provider<BackgroundWorkerLockService>(
  (_) => BackgroundWorkerLockService(BackgroundWorkerLockApi()),
);

final nativeSyncApiProvider = Provider<NativeSyncApi>((_) => NativeSyncApi());

final connectivityApiProvider = Provider<ConnectivityApi>((_) => ConnectivityApi());

final probeHttpTransportProvider = Provider<ProbeHttpTransportPort>((_) => NativeProbeHttpTransport());

final localImageApi = LocalImageApi();

final localImageApiProvider = Provider<LocalImageApi>((_) => localImageApi);

final remoteImageApi = RemoteImageApi();

final remoteImageApiProvider = Provider<RemoteImageApi>((_) => remoteImageApi);

final originalExportApiProvider = Provider<OriginalExportApi>((_) => OriginalExportApi());

final timelinePerformanceProvider = Provider<TimelinePerformancePort>(
  (_) => NativeTimelinePerformanceAdapter(api: PerformanceApi()),
);

final networkApi = NetworkApi();
