import Foundation

final class ManualClock {
  init(now: TimeInterval = 0) {
    self.now = now
  }

  private(set) var now: TimeInterval

  fileprivate func advance(to instant: TimeInterval) {
    precondition(instant >= now)
    now = instant
  }

  fileprivate func reset(to instant: TimeInterval) {
    now = instant
  }
}

final class ScheduledTask {
  fileprivate init() {}

  private(set) var isCancelled = false
  private(set) var isExecuted = false

  func cancel() {
    guard !isExecuted else { return }
    isCancelled = true
  }

  fileprivate func execute(_ action: () -> Void) {
    guard !isCancelled, !isExecuted else { return }
    isExecuted = true
    action()
  }
}

final class ManualScheduler {
  init(clock: ManualClock = ManualClock()) {
    self.clock = clock
  }

  let clock: ManualClock

  private struct Entry {
    let deadline: TimeInterval
    let order: Int
    let task: ScheduledTask
    let action: () -> Void
  }

  private var entries: [Entry] = []
  private var nextOrder = 0

  @discardableResult
  func schedule(after delay: TimeInterval, _ action: @escaping () -> Void) -> ScheduledTask {
    precondition(delay >= 0)
    let task = ScheduledTask()
    entries.append(Entry(deadline: clock.now + delay, order: nextOrder, task: task, action: action))
    nextOrder += 1
    return task
  }

  func advance(by interval: TimeInterval) {
    precondition(interval >= 0)
    let target = clock.now + interval

    while let index = nextEntryIndex(upTo: target) {
      let entry = entries.remove(at: index)
      clock.advance(to: entry.deadline)
      entry.task.execute(entry.action)
    }

    clock.advance(to: target)
  }

  func reset(to instant: TimeInterval = 0) {
    entries.removeAll()
    nextOrder = 0
    clock.reset(to: instant)
  }

  private func nextEntryIndex(upTo target: TimeInterval) -> Int? {
    entries.indices
      .filter { entries[$0].deadline <= target }
      .min {
        let lhs = entries[$0]
        let rhs = entries[$1]
        return lhs.deadline == rhs.deadline ? lhs.order < rhs.order : lhs.deadline < rhs.deadline
      }
  }
}
