import Foundation

final class ConcurrencyLease {
  fileprivate init(release: @escaping () -> Void) {
    self.releaseAction = release
  }

  private let lock = NSLock()
  private var releaseAction: (() -> Void)?

  func release() {
    lock.lock()
    let action = releaseAction
    releaseAction = nil
    lock.unlock()
    action?()
  }

  deinit {
    release()
  }
}

final class ConcurrencyCounter {
  private let lock = NSLock()
  private var activeCount = 0
  private var highestCount = 0

  var active: Int {
    lock.lock()
    defer { lock.unlock() }
    return activeCount
  }

  var peak: Int {
    lock.lock()
    defer { lock.unlock() }
    return highestCount
  }

  func begin() -> ConcurrencyLease {
    lock.lock()
    activeCount += 1
    highestCount = max(highestCount, activeCount)
    lock.unlock()

    return ConcurrencyLease { [weak self] in
      self?.end()
    }
  }

  func reset() {
    lock.lock()
    precondition(activeCount == 0, "Cannot reset while operations remain active")
    highestCount = 0
    lock.unlock()
  }

  private func end() {
    lock.lock()
    precondition(activeCount > 0, "Concurrency lease released more than once")
    activeCount -= 1
    lock.unlock()
  }
}
