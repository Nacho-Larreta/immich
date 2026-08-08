import Foundation

private let probeMaximumBodyBytes = 1024 * 1024
private let probeMaximumRedirects = 5

private enum ProbeHttpHeaderPolicy {
  private static let forbiddenNames = Set([
    "connection",
    "cookie",
    "host",
    "keep-alive",
    "proxy-authorization",
    "proxy-connection",
    "te",
    "trailer",
    "transfer-encoding",
    "upgrade",
  ])

  static func apply(_ headers: [String: String], to request: inout URLRequest) {
    for (name, value) in headers where !isForbidden(name) {
      request.setValue(value, forHTTPHeaderField: name)
    }
  }

  static func sanitize(_ request: URLRequest) -> URLRequest {
    var sanitized = request
    for name in request.allHTTPHeaderFields?.keys.filter(isForbidden) ?? [] {
      sanitized.setValue(nil, forHTTPHeaderField: name)
    }
    sanitized.httpShouldHandleCookies = false
    return sanitized
  }

  private static func isForbidden(_ name: String) -> Bool {
    forbiddenNames.contains(name.lowercased())
  }
}

struct ProbeHttpOrigin: Equatable, Sendable {
  let scheme: String
  let host: String
  let port: Int

  init?(url: URL, requireOriginOnly: Bool = false) {
    guard
      url.user == nil,
      url.password == nil,
      url.fragment == nil,
      !requireOriginOnly || (url.path.isEmpty || url.path == "/") && url.query == nil,
      let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased(),
      let port = Self.effectivePort(scheme: scheme, explicitPort: url.port)
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = port
  }

  private static func effectivePort(scheme: String, explicitPort: Int?) -> Int? {
    if let explicitPort { return explicitPort }
    switch scheme {
    case "http": return 80
    case "https": return 443
    default: return nil
    }
  }
}

private final class ProbeHttpRequestOperation: @unchecked Sendable {
  private struct State: Sendable {
    var task: URLSessionDataTask?
    var response: HTTPURLResponse?
    var data = Data()
    var redirectChain: [URL] = []
    var failure: NativeProbeHttpErrorCode?
    var completed = false
  }

  let id: Int64
  let requestURL: URL
  let origin: ProbeHttpOrigin
  private let completion: (Result<NativeProbeHttpResult, any Error>) -> Void
  private let state = Mutex(State())

  init(
    id: Int64,
    requestURL: URL,
    origin: ProbeHttpOrigin,
    completion: @escaping (Result<NativeProbeHttpResult, any Error>) -> Void
  ) {
    self.id = id
    self.requestURL = requestURL
    self.origin = origin
    self.completion = completion
  }

  var taskIdentifier: Int? {
    state.withLock { $0.task?.taskIdentifier }
  }

  func start(_ task: URLSessionDataTask) {
    let failure = state.withLock { state -> NativeProbeHttpErrorCode? in
      state.task = task
      return state.failure
    }
    if failure == nil {
      task.resume()
    } else {
      task.cancel()
    }
  }

  func receive(response: HTTPURLResponse) {
    state.withLock { $0.response = response }
  }

  func receive(data: Data) -> Bool {
    state.withLock { state in
      guard state.failure == nil else { return false }
      guard state.data.count <= probeMaximumBodyBytes - data.count else {
        state.failure = .bodyTooLarge
        return false
      }
      state.data.append(data)
      return true
    }
  }

  func allowRedirect(to url: URL) -> Bool {
    state.withLock { state in
      guard
        ProbeHttpOrigin(url: url) == origin,
        state.redirectChain.count < probeMaximumRedirects
      else {
        state.failure = .redirectRejected
        return false
      }
      state.redirectChain.append(url)
      return true
    }
  }

  func cancel() {
    let task = state.withLock { state -> URLSessionDataTask? in
      guard !state.completed else { return nil }
      state.failure = .cancelled
      return state.task
    }
    task?.cancel()
    finish(urlError: nil)
  }

  func finish(urlError: URLError?) {
    let result = state.withLock { state -> NativeProbeHttpResult? in
      guard !state.completed else { return nil }
      state.completed = true
      if let failure = state.failure {
        return NativeProbeHttpResult(response: nil, error: failure)
      }
      if urlError?.code == .timedOut {
        return NativeProbeHttpResult(response: nil, error: .timeout)
      }
      guard urlError == nil, let response = state.response, let effectiveURL = response.url else {
        return NativeProbeHttpResult(response: nil, error: .transportFailure)
      }
      guard let body = String(data: state.data, encoding: .utf8) else {
        return NativeProbeHttpResult(response: nil, error: .transportFailure)
      }
      return NativeProbeHttpResult(
        response: NativeProbeHttpResponse(
          requestUrl: requestURL.absoluteString,
          effectiveUrl: effectiveURL.absoluteString,
          statusCode: Int64(response.statusCode),
          body: body,
          redirectChain: state.redirectChain.map(\.absoluteString)
        ),
        error: nil
      )
    }
    if let result {
      completion(.success(result))
    }
  }
}

typealias ProbeHttpChallengeHandler = (
  URLSession,
  URLAuthenticationChallenge,
  URLSessionTask?,
  @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
) -> Void

private final class ProbeHttpSession: NSObject, URLSessionDataDelegate, @unchecked Sendable {

  private let operations = Mutex<[Int64: ProbeHttpRequestOperation]>([:])
  private let operationsByTask = Mutex<[Int: ProbeHttpRequestOperation]>([:])
  private let challengeHandler: ProbeHttpChallengeHandler
  private var session: URLSession!

  init(
    configuration sourceConfiguration: URLSessionConfiguration,
    timeout: TimeInterval,
    challengeHandler: @escaping ProbeHttpChallengeHandler
  ) {
    self.challengeHandler = challengeHandler
    super.init()
    let configuration = sourceConfiguration.copy() as! URLSessionConfiguration
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpCookieStorage = nil
    configuration.httpShouldSetCookies = false
    configuration.timeoutIntervalForRequest = timeout
    configuration.timeoutIntervalForResource = timeout
    session = URLSession(configuration: configuration, delegate: self, delegateQueue: nil)
  }

  func get(
    request input: NativeProbeHttpRequest,
    completion: @escaping (Result<NativeProbeHttpResult, any Error>) -> Void
  ) {
    guard
      let url = URL(string: input.url),
      let declaredOriginURL = URL(string: input.canonicalOrigin),
      let requestOrigin = ProbeHttpOrigin(url: url),
      let declaredOrigin = ProbeHttpOrigin(url: declaredOriginURL, requireOriginOnly: true),
      requestOrigin == declaredOrigin
    else {
      return completion(.success(NativeProbeHttpResult(response: nil, error: .invalidRequest)))
    }

    let operation = ProbeHttpRequestOperation(
      id: input.requestId,
      requestURL: url,
      origin: declaredOrigin,
      completion: completion
    )
    let inserted = operations.withLock { operations -> Bool in
      guard operations[input.requestId] == nil else { return false }
      operations[input.requestId] = operation
      return true
    }
    guard inserted else {
      return completion(.success(NativeProbeHttpResult(response: nil, error: .duplicateRequest)))
    }

    var request = URLRequest(url: url)
    request.cachePolicy = .reloadIgnoringLocalCacheData
    request.httpShouldHandleCookies = false
    ProbeHttpHeaderPolicy.apply(input.headers, to: &request)
    let task = session.dataTask(with: request)
    operationsByTask.withLock { $0[task.taskIdentifier] = operation }
    operation.start(task)
  }

  func cancel(requestId: Int64) {
    operations.withLock { $0.removeValue(forKey: requestId) }?.cancel()
  }

  func close() {
    let active = operations.withLock { operations -> [ProbeHttpRequestOperation] in
      let active = Array(operations.values)
      operations.removeAll()
      return active
    }
    operationsByTask.withLock { $0.removeAll() }
    for operation in active {
      operation.cancel()
    }
    session.invalidateAndCancel()
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard
      let operation = operationsByTask.withLock({ $0[dataTask.taskIdentifier] }),
      let response = response as? HTTPURLResponse
    else {
      completionHandler(.cancel)
      return
    }
    operation.receive(response: response)
    completionHandler(.allow)
  }

  func urlSession(_ session: URLSession, dataTask: URLSessionDataTask, didReceive data: Data) {
    guard let operation = operationsByTask.withLock({ $0[dataTask.taskIdentifier] }) else { return }
    if !operation.receive(data: data) {
      dataTask.cancel()
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let operation = operationsByTask.withLock({ $0[task.taskIdentifier] }),
      let redirectURL = request.url,
      operation.allowRedirect(to: redirectURL)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(ProbeHttpHeaderPolicy.sanitize(request))
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: (any Error)?
  ) {
    guard let operation = operationsByTask.withLock({ $0.removeValue(forKey: task.taskIdentifier) })
    else {
      return
    }
    operations.withLock { $0.removeValue(forKey: operation.id) }
    operation.finish(urlError: error as? URLError)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    challengeHandler(session, challenge, nil, completionHandler)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    challengeHandler(session, challenge, task, completionHandler)
  }
}

final class ProbeHttpApiImpl: ProbeHttpApi {
  private let sessions = Mutex<[Int64: ProbeHttpSession]>([:])
  private let challengeHandler: ProbeHttpChallengeHandler
  private let configurationFactory: () -> URLSessionConfiguration

  init() {
    let manager = URLSessionManager.shared
    challengeHandler = { session, challenge, task, completion in
      manager.delegate.handleChallenge(session, challenge, completion, task: task)
    }
    configurationFactory = { URLSessionConfiguration.ephemeral }
  }

  init(
    configurationFactory: @escaping () -> URLSessionConfiguration,
    challengeHandler: @escaping ProbeHttpChallengeHandler = { _, _, _, completion in
      completion(.performDefaultHandling, nil)
    }
  ) {
    self.configurationFactory = configurationFactory
    self.challengeHandler = challengeHandler
  }

  func openSession(session input: NativeProbeHttpSession) throws {
    guard input.sessionId > 0, input.timeoutMilliseconds > 0 else {
      throw NSError(
        domain: "ProbeHttpApi",
        code: 1,
        userInfo: [NSLocalizedDescriptionKey: "Probe session ID and timeout must be positive"]
      )
    }
    let session = ProbeHttpSession(
      configuration: configurationFactory(),
      timeout: TimeInterval(input.timeoutMilliseconds) / 1000,
      challengeHandler: challengeHandler
    )
    let inserted = sessions.withLock { sessions -> Bool in
      guard sessions[input.sessionId] == nil else { return false }
      sessions[input.sessionId] = session
      return true
    }
    guard inserted else {
      session.close()
      throw NSError(
        domain: "ProbeHttpApi",
        code: 2,
        userInfo: [NSLocalizedDescriptionKey: "Probe session ID is already active"]
      )
    }
  }

  func get(
    request: NativeProbeHttpRequest,
    completion: @escaping (Result<NativeProbeHttpResult, any Error>) -> Void
  ) {
    guard let session = sessions.withLock({ $0[request.sessionId] }) else {
      return completion(.success(NativeProbeHttpResult(response: nil, error: .sessionNotFound)))
    }
    session.get(request: request, completion: completion)
  }

  func cancelRequest(sessionId: Int64, requestId: Int64) throws {
    sessions.withLock { $0[sessionId] }?.cancel(requestId: requestId)
  }

  func closeSession(sessionId: Int64) throws {
    sessions.withLock { $0.removeValue(forKey: sessionId) }?.close()
  }
}
