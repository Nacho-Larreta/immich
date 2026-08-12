import Foundation

public struct BackgroundDownloaderRequestContextSnapshot: Equatable, Sendable {
  public init(
    revision: UInt64,
    headers: [String: String],
    cookieHeader: String?,
    sensitiveHeaderNames: Set<String>
  ) {
    self.revision = revision
    self.headers = headers
    self.cookieHeader = cookieHeader
    self.sensitiveHeaderNames = Set(sensitiveHeaderNames.map { $0.lowercased() })
  }

  public let revision: UInt64
  public let headers: [String: String]
  public let cookieHeader: String?
  public let sensitiveHeaderNames: Set<String>
}

public struct BackgroundDownloaderPreparedRequest {
  public let request: URLRequest
  public let context: BackgroundDownloaderRequestContextSnapshot
}

public enum BackgroundDownloaderExecutionMode: Equatable {
  case foreground
  case background
}

public enum BackgroundDownloaderRequestContextBridge {
  public typealias Capture = (URL) -> BackgroundDownloaderRequestContextSnapshot?
  public typealias IsCurrent = (UInt64, URL) -> Bool
  public typealias ChallengeHandler = (
    URLSession,
    URLAuthenticationChallenge,
    URLSessionTask?,
    @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) -> Void

  private struct Integration {
    let capture: Capture
    let isCurrent: IsCurrent
    let challengeHandler: ChallengeHandler
  }

  private static let lock = NSLock()
  private static var integration: Integration?
  private static var tasks:
    [ObjectIdentifier: (URLSessionTask, BackgroundDownloaderRequestContextSnapshot)] = [:]

  public static func install(
    capture: @escaping Capture,
    isCurrent: @escaping IsCurrent,
    challengeHandler: @escaping ChallengeHandler
  ) {
    let staleTasks = lock.withLock { () -> [URLSessionTask] in
      let staleTasks = tasks.values.map(\.0)
      tasks.removeAll()
      integration = Integration(
        capture: capture,
        isCurrent: isCurrent,
        challengeHandler: challengeHandler
      )
      return staleTasks
    }
    for task in staleTasks {
      task.cancel()
    }
  }

  public static func reset() {
    let staleTasks = lock.withLock { () -> [URLSessionTask] in
      let staleTasks = tasks.values.map(\.0)
      tasks.removeAll()
      integration = nil
      return staleTasks
    }
    for task in staleTasks {
      task.cancel()
    }
  }

  public static var isInstalled: Bool {
    lock.withLock { integration != nil }
  }

  public static func executionMode(for url: URL) -> BackgroundDownloaderExecutionMode {
    url.scheme?.lowercased() == "https" ? .background : .foreground
  }

  public static func cancelRestoredTasks(_ restoredTasks: [URLSessionTask]) -> Int {
    guard isInstalled else { return 0 }
    let unboundTasks = lock.withLock {
      restoredTasks.filter { tasks[ObjectIdentifier($0)] == nil }
    }
    for task in unboundTasks {
      task.cancel()
    }
    return unboundTasks.count
  }

  public static func shouldProcessCallback(for task: URLSessionTask) -> Bool {
    guard isInstalled else { return true }
    guard let context = context(for: task) else { return false }
    return isCurrent(context, for: task.currentRequest?.url ?? task.originalRequest?.url)
  }

  public static func resetForProcessTerminationSimulation() {
    lock.withLock {
      tasks.removeAll()
      integration = nil
    }
  }

  public static func secureConfiguration(_ configuration: URLSessionConfiguration) {
    guard isInstalled else { return }
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.httpAdditionalHeaders = nil
  }

  public static func prepare(
    _ request: URLRequest,
    expectedRevision: UInt64? = nil
  ) -> BackgroundDownloaderPreparedRequest? {
    guard
      let url = request.url,
      let integration = lock.withLock({ integration }),
      let context = integration.capture(url),
      expectedRevision == nil || context.revision == expectedRevision
    else { return nil }
    return BackgroundDownloaderPreparedRequest(
      request: secure(request, with: context),
      context: context
    )
  }

  @discardableResult
  public static func resume(
    _ task: URLSessionTask,
    context: BackgroundDownloaderRequestContextSnapshot?
  ) -> Bool {
    guard let context else {
      task.resume()
      return true
    }
    lock.withLock {
      tasks[ObjectIdentifier(task)] = (task, context)
    }
    guard isCurrent(context, for: task.originalRequest?.url ?? task.currentRequest?.url) else {
      complete(task)
      task.cancel()
      return false
    }
    task.resume()
    return true
  }

  public static func securedDelayedRequest(
    _ request: URLRequest,
    for task: URLSessionTask
  ) -> URLRequest? {
    guard isInstalled else { return request }
    guard
      let context = context(for: task),
      isCurrent(context, for: request.url)
    else { return nil }
    return secure(request, with: context)
  }

  public static func securedRedirect(
    _ request: URLRequest,
    for task: URLSessionTask
  ) -> URLRequest? {
    securedDelayedRequest(request, for: task)
  }

  public static func handleChallenge(
    session: URLSession,
    challenge: URLAuthenticationChallenge,
    task: URLSessionTask?,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let integration = lock.withLock({ integration }) else {
      completion(.performDefaultHandling, nil)
      return
    }
    if let task {
      guard
        let context = context(for: task),
        isCurrent(context, for: task.currentRequest?.url ?? task.originalRequest?.url)
      else {
        completion(.cancelAuthenticationChallenge, nil)
        return
      }
    } else {
      let activeTasks = lock.withLock { Array(tasks.values) }
      guard
        activeTasks.contains(where: { task, context in
          isCurrent(context, for: task.currentRequest?.url ?? task.originalRequest?.url)
        })
      else {
        completion(.cancelAuthenticationChallenge, nil)
        return
      }
    }
    integration.challengeHandler(session, challenge, task, completion)
  }

  public static func complete(_ task: URLSessionTask) {
    _ = lock.withLock {
      tasks.removeValue(forKey: ObjectIdentifier(task))
    }
  }

  public static func contextDidChange() {
    let staleTasks = lock.withLock { () -> [URLSessionTask] in
      let staleTasks = tasks.values.map(\.0)
      tasks.removeAll()
      return staleTasks
    }
    for task in staleTasks {
      task.cancel()
    }
  }

  private static func context(
    for task: URLSessionTask
  ) -> BackgroundDownloaderRequestContextSnapshot? {
    lock.withLock { tasks[ObjectIdentifier(task)]?.1 }
  }

  private static func isCurrent(
    _ context: BackgroundDownloaderRequestContextSnapshot,
    for url: URL?
  ) -> Bool {
    guard
      let url,
      let integration = lock.withLock({ integration })
    else { return false }
    return integration.isCurrent(context.revision, url)
  }

  private static func secure(
    _ request: URLRequest,
    with context: BackgroundDownloaderRequestContextSnapshot
  ) -> URLRequest {
    var secured = request
    let sensitiveNames = context.sensitiveHeaderNames.union(["authorization", "cookie"])
    for header in request.allHTTPHeaderFields.map({ Array($0.keys) }) ?? []
    where sensitiveNames.contains(header.lowercased()) {
      secured.setValue(nil, forHTTPHeaderField: header)
    }
    for (header, value) in context.headers
    where header.caseInsensitiveCompare("Cookie") != .orderedSame {
      secured.setValue(value, forHTTPHeaderField: header)
    }
    secured.setValue(context.cookieHeader, forHTTPHeaderField: "Cookie")
    return secured
  }

}
