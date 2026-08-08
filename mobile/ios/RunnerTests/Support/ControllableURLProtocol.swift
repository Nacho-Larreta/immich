import Foundation

final class ControlledURLRequest {
  fileprivate init(protocolInstance: URLProtocol) {
    self.protocolInstance = protocolInstance
  }

  private enum State {
    case active
    case finished
    case stopped
  }

  private let lock = NSLock()
  private weak var protocolInstance: URLProtocol?
  private var state = State.active
  private var didSendResponse = false

  var request: URLRequest? {
    protocolInstance?.request
  }

  @discardableResult
  func respond(statusCode: Int, headers: [String: String] = [:]) -> Bool {
    lock.lock()
    guard
      state == .active,
      !didSendResponse,
      let protocolInstance,
      let url = protocolInstance.request.url,
      let response = HTTPURLResponse(
        url: url,
        statusCode: statusCode,
        httpVersion: nil,
        headerFields: headers
      )
    else {
      lock.unlock()
      return false
    }
    didSendResponse = true
    lock.unlock()
    protocolInstance.client?.urlProtocol(
      protocolInstance,
      didReceive: response,
      cacheStoragePolicy: .allowed
    )
    return true
  }

  @discardableResult
  func send(_ data: Data) -> Bool {
    lock.lock()
    guard state == .active, didSendResponse, let protocolInstance else {
      lock.unlock()
      return false
    }
    lock.unlock()
    protocolInstance.client?.urlProtocol(protocolInstance, didLoad: data)
    return true
  }

  @discardableResult
  func finish() -> Bool {
    transitionToTerminal(.finished) { protocolInstance in
      protocolInstance.client?.urlProtocolDidFinishLoading(protocolInstance)
    }
  }

  @discardableResult
  func fail(_ error: Error) -> Bool {
    transitionToTerminal(.finished) { protocolInstance in
      protocolInstance.client?.urlProtocol(protocolInstance, didFailWithError: error)
    }
  }

  @discardableResult
  fileprivate func stop() -> Bool {
    transitionToTerminal(.stopped) { _ in }
  }

  private func transitionToTerminal(
    _ terminalState: State,
    completion: (URLProtocol) -> Void
  ) -> Bool {
    lock.lock()
    guard state == .active, let protocolInstance else {
      lock.unlock()
      return false
    }
    state = terminalState
    lock.unlock()
    completion(protocolInstance)
    return true
  }
}

final class ControllableURLProtocol: URLProtocol {
  typealias RequestHandler = (ControlledURLRequest) -> Void

  private final class Registry {
    let lock = NSLock()
    var handler: RequestHandler?
    var requests: [ControlledURLRequest] = []
  }

  private static let registry = Registry()
  private var controlledRequest: ControlledURLRequest?

  static func setRequestHandler(_ handler: @escaping RequestHandler) {
    registry.lock.lock()
    registry.handler = handler
    registry.lock.unlock()
  }

  static var observedRequests: [ControlledURLRequest] {
    registry.lock.lock()
    defer { registry.lock.unlock() }
    return registry.requests
  }

  static func reset() {
    registry.lock.lock()
    registry.handler = nil
    registry.requests.removeAll()
    registry.lock.unlock()
  }

  override class func canInit(with request: URLRequest) -> Bool {
    true
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest {
    request
  }

  override func startLoading() {
    let controlledRequest = ControlledURLRequest(protocolInstance: self)
    self.controlledRequest = controlledRequest

    Self.registry.lock.lock()
    Self.registry.requests.append(controlledRequest)
    let handler = Self.registry.handler
    Self.registry.lock.unlock()

    guard let handler else {
      controlledRequest.fail(URLError(.resourceUnavailable))
      return
    }
    handler(controlledRequest)
  }

  override func stopLoading() {
    controlledRequest?.stop()
  }
}

final class URLSessionTestContext {
  fileprivate init(session: URLSession, cache: URLCache, cookieStorage: HTTPCookieStorage) {
    self.session = session
    self.cache = cache
    self.cookieStorage = cookieStorage
  }

  let session: URLSession
  let cache: URLCache
  let cookieStorage: HTTPCookieStorage

  func reset() {
    session.invalidateAndCancel()
    cache.removeAllCachedResponses()
    cookieStorage.cookies?.forEach(cookieStorage.deleteCookie)
    ControllableURLProtocol.reset()
  }
}

enum URLSessionTestFactory {
  static func make(
    memoryCapacity: Int = 4 * 1024 * 1024,
    diskCapacity: Int = 0
  ) -> URLSessionTestContext {
    let cache = URLCache(memoryCapacity: memoryCapacity, diskCapacity: diskCapacity, diskPath: nil)
    let cookieStorage = HTTPCookieStorage.sharedCookieStorage(
      forGroupContainerIdentifier: "RunnerTests.\(UUID().uuidString)"
    )
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ControllableURLProtocol.self]
    configuration.urlCache = cache
    configuration.httpCookieStorage = cookieStorage
    configuration.requestCachePolicy = .useProtocolCachePolicy
    let session = URLSession(configuration: configuration)
    return URLSessionTestContext(session: session, cache: cache, cookieStorage: cookieStorage)
  }
}
