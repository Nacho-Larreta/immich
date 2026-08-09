import 'dart:async';
import 'dart:io';

import 'package:immich_mobile/domain/interfaces/timeline_performance.interface.dart';
import 'package:immich_mobile/platform/performance_api.g.dart';

final class NativeTimelinePerformanceAdapter implements TimelinePerformancePort {
  NativeTimelinePerformanceAdapter({required PerformanceApi api, bool? isSupported})
    : _api = api,
      _isSupported = isSupported ?? Platform.isIOS;

  final PerformanceApi _api;
  final bool _isSupported;

  @override
  void recordTimelineInteractive() {
    if (!_isSupported) return;
    unawaited(_api.timelineInteractive().catchError((_) {}));
  }
}
