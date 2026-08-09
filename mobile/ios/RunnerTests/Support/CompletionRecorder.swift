import Foundation

final class CompletionRecorder<Value> {
  private let lock = NSLock()
  private var completionCount = 0
  private var storedResult: Result<Value, Error>?

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return completionCount
  }

  var result: Result<Value, Error>? {
    lock.lock()
    defer { lock.unlock() }
    return storedResult
  }

  @discardableResult
  func record(_ result: Result<Value, Error>) -> Bool {
    lock.lock()
    defer { lock.unlock() }
    completionCount += 1
    guard storedResult == nil else { return false }
    storedResult = result
    return true
  }

  func reset() {
    lock.lock()
    completionCount = 0
    storedResult = nil
    lock.unlock()
  }
}
