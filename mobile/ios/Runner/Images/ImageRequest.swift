import Foundation

class ImageRequest<Value>: @unchecked Sendable {
  private struct State: Sendable {
    var isCancelled = false
    var isCompleted = false
  }

  let completion: (Result<Value, any Error>) -> Void
  private let state: Mutex<State>

  var isCancelled: Bool {
    state.withLock { $0.isCancelled }
  }

  init(completion: @escaping (Result<Value, any Error>) -> Void) {
    self.state = Mutex(State())
    self.completion = completion
  }

  @discardableResult
  func cancel() -> Bool {
    state.withLock {
      guard !$0.isCancelled, !$0.isCompleted else { return false }
      $0.isCancelled = true
      return true
    }
  }

  @discardableResult
  func complete(_ result: Result<Value, any Error>) -> Bool {
    let shouldComplete = state.withLock {
      guard !$0.isCompleted else { return false }
      $0.isCompleted = true
      return true
    }
    guard shouldComplete else { return false }
    completion(result)
    return true
  }
}

final class RequestRegistry<T: AnyObject & Sendable>: @unchecked Sendable {
  private let requests = Mutex<[Int64: T]>([:])

  @discardableResult
  func addIfAbsent(requestId: Int64, request: T) -> Bool {
    requests.withLock {
      guard $0[requestId] == nil else { return false }
      $0[requestId] = request
      return true
    }
  }

  @discardableResult
  func add(requestId: Int64, request: T) -> T? {
    requests.withLock { $0.updateValue(request, forKey: requestId) }
  }

  @discardableResult
  func remove(requestId: Int64) -> T? {
    requests.withLock { $0.removeValue(forKey: requestId) }
  }

  @discardableResult
  func remove(requestId: Int64, matching request: T) -> T? {
    requests.withLock {
      guard $0[requestId] === request else { return nil }
      return $0.removeValue(forKey: requestId)
    }
  }

  func removeAll() -> [T] {
    requests.withLock {
      let removed = Array($0.values)
      $0.removeAll()
      return removed
    }
  }
}
