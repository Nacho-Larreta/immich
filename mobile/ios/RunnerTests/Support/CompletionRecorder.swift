import Foundation

final class CompletionRecorder<Value> {
  private let lock = NSLock()
  private var storedResult: Result<Value, Error>?

  var count: Int {
    lock.lock()
    defer { lock.unlock() }
    return storedResult == nil ? 0 : 1
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
    guard storedResult == nil else { return false }
    storedResult = result
    return true
  }

  func reset() {
    lock.lock()
    storedResult = nil
    lock.unlock()
  }
}
