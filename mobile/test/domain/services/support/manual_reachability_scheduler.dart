import 'package:immich_mobile/domain/interfaces/reachability_scheduler.interface.dart';

final class ManualReachabilityScheduler implements ReachabilitySchedulerPort {
  Duration _now = Duration.zero;
  int _sequence = 0;
  final List<_ManualTask> _tasks = [];

  int get activeTaskCount => _tasks.where((task) => task.isActive).length;

  @override
  ScheduledReachabilityTask schedule(Duration delay, void Function() callback) {
    if (delay.isNegative) {
      throw ArgumentError.value(delay, 'delay', 'Must not be negative');
    }
    final task = _ManualTask(deadline: _now + delay, sequence: _sequence++, callback: callback);
    _tasks.add(task);
    return task;
  }

  void elapse(Duration duration) {
    if (duration.isNegative) {
      throw ArgumentError.value(duration, 'duration', 'Must not be negative');
    }
    final target = _now + duration;
    while (true) {
      final due = _nextDueTask(target);
      if (due == null) {
        break;
      }
      _now = due.deadline;
      due.run();
    }
    _now = target;
  }

  _ManualTask? _nextDueTask(Duration target) {
    final due = _tasks.where((task) => task.isActive && task.deadline <= target).toList()
      ..sort((left, right) {
        final byDeadline = left.deadline.compareTo(right.deadline);
        return byDeadline == 0 ? left.sequence.compareTo(right.sequence) : byDeadline;
      });
    return due.firstOrNull;
  }
}

final class _ManualTask implements ScheduledReachabilityTask {
  _ManualTask({required this.deadline, required this.sequence, required this.callback});

  final Duration deadline;
  final int sequence;
  final void Function() callback;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  void cancel() => _active = false;

  void run() {
    if (!_active) {
      return;
    }
    _active = false;
    callback();
  }
}
