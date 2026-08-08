import Foundation

class ImageRequest<Value>: @unchecked Sendable {
  private struct State: Sendable {
    var isCancelled = false
  }

  let completion: @Sendable (Result<Value, any Error>) -> Void
  private let state: Mutex<State>

  var isCancelled: Bool {
    get {
      state.withLock { $0.isCancelled }
    }
    set {
      state.withLock { $0.isCancelled = newValue }
    }
  }

  init(completion: @escaping @Sendable (Result<Value, any Error>) -> Void) {
    self.state = Mutex(State())
    self.completion = completion
  }

  func cancel() {
    isCancelled = true
  }
}

struct RequestRegistry<T: AnyObject & Sendable>: ~Copyable, Sendable {
  private let requests = Mutex<[Int64: T]>([:])

  func add(requestId: Int64, request: T) {
    requests.withLock { $0[requestId] = request }
  }

  @discardableResult
  func remove(requestId: Int64) -> T? {
    requests.withLock { $0.removeValue(forKey: requestId) }
  }

  func removeAll() -> [T] {
    requests.withLock {
      let removed = Array($0.values)
      $0.removeAll()
      return removed
    }
  }
}
