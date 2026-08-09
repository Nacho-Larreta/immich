abstract interface class ReachabilitySchedulerPort {
  ScheduledReachabilityTask schedule(Duration delay, void Function() callback);
}

abstract interface class ScheduledReachabilityTask {
  bool get isActive;

  void cancel();
}
