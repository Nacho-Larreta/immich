import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/adapters/performance/native_timeline_performance_adapter.dart';
import 'package:immich_mobile/platform/performance_api.g.dart';

void main() {
  test('reports through the native bridge without awaiting completion', () {
    final api = _RecordingPerformanceApi();
    final adapter = NativeTimelinePerformanceAdapter(api: api, isSupported: true);

    adapter.recordTimelineInteractive();

    expect(api.callCount, 1);
    api.complete();
  });

  test('does not call the native bridge on unsupported platforms', () {
    final api = _RecordingPerformanceApi();
    final adapter = NativeTimelinePerformanceAdapter(api: api, isSupported: false);

    adapter.recordTimelineInteractive();

    expect(api.callCount, 0);
  });

  test('absorbs native bridge failures', () async {
    final api = _RecordingPerformanceApi();
    final adapter = NativeTimelinePerformanceAdapter(api: api, isSupported: true);

    adapter.recordTimelineInteractive();
    api.fail();
    await Future<void>.delayed(Duration.zero);

    expect(api.callCount, 1);
  });
}

final class _RecordingPerformanceApi extends PerformanceApi {
  final Completer<void> _completion = Completer<void>();
  var callCount = 0;

  @override
  Future<void> timelineInteractive() {
    callCount += 1;
    return _completion.future;
  }

  void complete() => _completion.complete();

  void fail() => _completion.completeError(StateError('bridge failed'));
}
