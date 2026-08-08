import Foundation

enum ControlledRequestError: Error {
  case cancelled
}

final class ControlledRequest<Value> {
  typealias Completion = (Result<Value, Error>) -> Void

  private let lock = NSLock()
  private var completion: Completion?
  private var terminalResult: Result<Value, Error>?

  func onComplete(_ completion: @escaping Completion) {
    lock.lock()
    if let terminalResult {
      lock.unlock()
      completion(terminalResult)
      return
    }
    precondition(self.completion == nil, "ControlledRequest supports one completion")
    self.completion = completion
    lock.unlock()
  }

  @discardableResult
  func succeed(_ value: Value) -> Bool {
    finish(with: .success(value))
  }

  @discardableResult
  func fail(_ error: Error) -> Bool {
    finish(with: .failure(error))
  }

  @discardableResult
  func cancel() -> Bool {
    finish(with: .failure(ControlledRequestError.cancelled))
  }

  func reset() {
    lock.lock()
    completion = nil
    terminalResult = nil
    lock.unlock()
  }

  private func finish(with result: Result<Value, Error>) -> Bool {
    lock.lock()
    guard terminalResult == nil else {
      lock.unlock()
      return false
    }
    terminalResult = result
    let completion = completion
    lock.unlock()
    completion?(result)
    return true
  }
}
