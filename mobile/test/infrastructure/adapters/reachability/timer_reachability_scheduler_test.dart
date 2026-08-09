import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:immich_mobile/infrastructure/adapters/reachability/timer_reachability_scheduler.dart';

void main() {
  test('runs a scheduled callback once and reports its active lifecycle', () async {
    final fired = Completer<void>();
    final task = const TimerReachabilityScheduler().schedule(const Duration(milliseconds: 5), fired.complete);

    expect(task.isActive, isTrue);
    await fired.future;
    expect(task.isActive, isFalse);
  });

  test('cancel prevents a pending callback', () async {
    var calls = 0;
    final task = const TimerReachabilityScheduler().schedule(const Duration(milliseconds: 5), () => calls++);

    task.cancel();
    await Future<void>.delayed(const Duration(milliseconds: 10));

    expect(task.isActive, isFalse);
    expect(calls, 0);
  });
}
