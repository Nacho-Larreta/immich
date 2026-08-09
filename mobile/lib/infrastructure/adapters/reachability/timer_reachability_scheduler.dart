import 'dart:async';

import 'package:immich_mobile/domain/interfaces/reachability_scheduler.interface.dart';

final class TimerReachabilityScheduler implements ReachabilitySchedulerPort {
  const TimerReachabilityScheduler();

  @override
  ScheduledReachabilityTask schedule(Duration delay, void Function() callback) {
    return _TimerReachabilityTask(Timer(delay, callback));
  }
}

final class _TimerReachabilityTask implements ScheduledReachabilityTask {
  const _TimerReachabilityTask(this._timer);

  final Timer _timer;

  @override
  bool get isActive => _timer.isActive;

  @override
  void cancel() => _timer.cancel();
}
