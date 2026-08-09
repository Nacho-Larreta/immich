import Foundation

final class RemoteOriginalExportSessionDelegate: NSObject, URLSessionDataDelegate {
  typealias ChallengeHandler = (
    URLSession,
    URLAuthenticationChallenge,
    URLSessionTask?,
    @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) -> Void

  private final class Context: @unchecked Sendable {
    init(
      operation: OriginalExportOperation,
      writer: OriginalExportLeaseWriter,
      authorization: NetworkOriginAuthorization,
      expectedLength: Int64,
      progress: @escaping (Double) -> Void
    ) {
      self.operation = operation
      self.writer = writer
      self.authorization = authorization
      self.expectedLength = expectedLength
      self.progress = progress
    }

    let operation: OriginalExportOperation
    let writer: OriginalExportLeaseWriter
    let authorization: NetworkOriginAuthorization
    var expectedLength: Int64
    var receivedLength: Int64 = 0
    var acceptedResponse = false
    let progress: (Double) -> Void
  }

  private struct State {
    var contexts: [Int: Context] = [:]
    var pendingWrites = 0
    var peakPendingWrites = 0
  }

  init(
    challengeHandler: ChallengeHandler?,
    ioExecutor: any OriginalExportIOExecuting
  ) {
    self.challengeHandler = challengeHandler
    self.ioExecutor = ioExecutor
  }

  private let challengeHandler: ChallengeHandler?
  private let ioExecutor: any OriginalExportIOExecuting
  private let state = Mutex(State())
  weak var owner: RemoteOriginalExporter?

  var peakPendingWriteCount: Int { state.withLock { $0.peakPendingWrites } }

  func register(
    task: URLSessionTask,
    operation: OriginalExportOperation,
    writer: OriginalExportLeaseWriter,
    authorization: NetworkOriginAuthorization,
    progress: @escaping (Double) -> Void
  ) {
    state.withLock {
      $0.contexts[task.taskIdentifier] = Context(
        operation: operation,
        writer: writer,
        authorization: authorization,
        expectedLength: NSURLSessionTransferSizeUnknown,
        progress: progress
      )
    }
  }

  func unregister(taskIdentifier: Int) {
    state.withLock { $0.contexts.removeValue(forKey: taskIdentifier) }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let context = state.withLock { $0.contexts[task.taskIdentifier] }
    guard
      let context,
      let redirectURL = request.url,
      URLSessionManager.allows(redirectURL, under: context.authorization)
    else {
      completionHandler(nil)
      if let context { owner?.finish(context.operation, failure: .wrongServer, cancelNative: true) }
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive response: URLResponse,
    completionHandler: @escaping (URLSession.ResponseDisposition) -> Void
  ) {
    guard let context = state.withLock({ $0.contexts[dataTask.taskIdentifier] }) else {
      completionHandler(.cancel)
      return
    }
    guard
      let response = response as? HTTPURLResponse,
      let responseURL = response.url,
      URLSessionManager.allows(responseURL, under: context.authorization)
    else {
      completionHandler(.cancel)
      owner?.finish(context.operation, failure: .wrongServer, cancelNative: true)
      return
    }
    guard (200..<300).contains(response.statusCode) else {
      completionHandler(.cancel)
      let failure: OriginalExportFailure = response.statusCode == 401 ? .unauthorized : .httpFailure
      owner?.finish(context.operation, failure: failure, cancelNative: true)
      return
    }
    ioExecutor.execute { [weak self, weak context] in
      guard let self, let context, context.operation.isActive else {
        completionHandler(.cancel)
        return
      }
      do {
        try context.writer.open()
        context.acceptedResponse = true
        context.expectedLength = response.expectedContentLength
        completionHandler(.allow)
      } catch let failure as OriginalExportFailure {
        completionHandler(.cancel)
        self.owner?.finish(context.operation, failure: failure, cancelNative: true)
      } catch {
        completionHandler(.cancel)
        self.owner?.finish(
          context.operation,
          failure: .storageUnavailable,
          cancelNative: true
        )
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    dataTask: URLSessionDataTask,
    didReceive data: Data
  ) {
    guard
      let context = state.withLock({ state -> Context? in
        guard let context = state.contexts[dataTask.taskIdentifier] else { return nil }
        state.pendingWrites += 1
        state.peakPendingWrites = max(state.peakPendingWrites, state.pendingWrites)
        return context
      })
    else { return }
    dataTask.suspend()
    let writeCompleted = DispatchSemaphore(value: 0)
    ioExecutor.execute { [weak self, weak context] in
      defer { writeCompleted.signal() }
      guard let self, let context, context.acceptedResponse, context.operation.isActive else {
        return
      }
      do {
        try context.writer.append(data)
        context.receivedLength += Int64(data.count)
        if context.expectedLength > 0 {
          context.progress(min(1, Double(context.receivedLength) / Double(context.expectedLength)))
        }
      } catch {
        self.owner?.finish(context.operation, failure: .writeFailed, cancelNative: true)
      }
    }
    writeCompleted.wait()
    state.withLock { $0.pendingWrites -= 1 }
    dataTask.resume()
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didCompleteWithError error: Error?
  ) {
    guard let context = state.withLock({ $0.contexts.removeValue(forKey: task.taskIdentifier) })
    else {
      return
    }
    let failure: OriginalExportFailure? = error.map {
      ($0 as? URLError)?.code == .cancelled ? .cancelled : .serverUnavailable
    }
    ioExecutor.execute { [weak self] in
      guard let self else { return }
      if let failure {
        self.owner?.nativeCompleted(context.operation, failure: failure)
      } else if context.acceptedResponse, context.receivedLength > 0 {
        self.owner?.nativeCompleted(context.operation, failure: nil)
      } else {
        self.owner?.nativeCompleted(context.operation, failure: .httpFailure)
      }
    }
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    handleChallenge(session, challenge: challenge, task: nil, completion: completionHandler)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    handleChallenge(session, challenge: challenge, task: task, completion: completionHandler)
  }

  private func handleChallenge(
    _ session: URLSession,
    challenge: URLAuthenticationChallenge,
    task: URLSessionTask?,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard
      let task,
      let context = state.withLock({ $0.contexts[task.taskIdentifier] }),
      let requestURL = task.currentRequest?.url ?? task.originalRequest?.url,
      URLSessionManager.allows(requestURL, under: context.authorization),
      let challengeHandler
    else {
      completion(.performDefaultHandling, nil)
      return
    }
    challengeHandler(session, challenge, task, completion)
  }
}

final class RemoteOriginalExporter: NSObject, @unchecked Sendable {
  // A fixed deadline bounds a stalled NAS response without treating individual slow chunks as activity.
  static let standardTimeout: TimeInterval = 120

  convenience override init() {
    let manager = URLSessionManager.shared
    self.init(
      sessionConfiguration: manager.session.configuration,
      challengeHandler: { session, challenge, task, completion in
        manager.delegate.handleChallenge(session, challenge, completion, task: task)
      },
      fileStore: TemporaryOriginalExportFileStore(),
      ioExecutor: SerialOriginalExportIOExecutor(),
      scheduler: DispatchOriginalExportTimeoutScheduler(),
      timeout: Self.standardTimeout,
      progressHandler: { _ in }
    )
  }

  init(
    sessionConfiguration: URLSessionConfiguration,
    challengeHandler: RemoteOriginalExportSessionDelegate.ChallengeHandler? = nil,
    fileStore: any OriginalExportFileStoring = TemporaryOriginalExportFileStore(),
    ioExecutor: any OriginalExportIOExecuting = SerialOriginalExportIOExecutor(),
    scheduler: any OriginalExportTimeoutScheduling = DispatchOriginalExportTimeoutScheduler(),
    pool: OriginalExportPermitPool = OriginalExportPermitPool(limit: 2),
    leaseRegistry: OriginalExportLeaseRegistry? = nil,
    timeout: TimeInterval = RemoteOriginalExporter.standardTimeout,
    progressHandler: @escaping (OriginalExportProgress) -> Void
  ) {
    precondition(timeout > 0)
    let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
    let cookieStorage = configuration.httpCookieStorage
    configuration.urlCache = nil
    configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.httpAdditionalHeaders = nil
    let delegate = RemoteOriginalExportSessionDelegate(
      challengeHandler: challengeHandler,
      ioExecutor: ioExecutor
    )
    let delegateQueue = OperationQueue()
    delegateQueue.name = "app.immich.remote-original-export"
    delegateQueue.maxConcurrentOperationCount = 1
    delegateQueue.qualityOfService = .userInitiated
    self.sessionDelegate = delegate
    self.session = URLSession(
      configuration: configuration,
      delegate: delegate,
      delegateQueue: delegateQueue
    )
    self.cookieStorage = cookieStorage
    self.fileStore = fileStore
    self.ioExecutor = ioExecutor
    self.scheduler = scheduler
    self.pool = pool
    self.leaseRegistry = leaseRegistry ?? OriginalExportLeaseRegistry(ioExecutor: ioExecutor)
    self.timeout = timeout
    self.progressHandler = progressHandler
    super.init()
    delegate.owner = self
  }

  private let sessionDelegate: RemoteOriginalExportSessionDelegate
  private let session: URLSession
  private let cookieStorage: HTTPCookieStorage?
  private let fileStore: any OriginalExportFileStoring
  private let ioExecutor: any OriginalExportIOExecuting
  private let scheduler: any OriginalExportTimeoutScheduling
  private let pool: OriginalExportPermitPool
  private let leaseRegistry: OriginalExportLeaseRegistry
  private let timeout: TimeInterval
  private let progressHandler: (OriginalExportProgress) -> Void
  private let registry = RequestRegistry<OriginalExportOperation>()
  private let lifecycle = Mutex(false)

  var peakPendingWriteCount: Int { sessionDelegate.peakPendingWriteCount }
  var activeCount: Int { pool.activeCount }
  var peakActiveCount: Int { pool.peakActiveCount }
  var usesURLCache: Bool { session.configuration.urlCache != nil }

  func export(
    request: RemoteOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    guard
      let url = URL(string: request.url),
      let authorization = URLSessionManager.authorize(url, declaredOrigin: request.origin)
    else {
      completion(.success(.failure(.wrongServer)))
      return
    }

    let operation = OriginalExportOperation(
      id: request.requestId,
      ioExecutor: ioExecutor,
      leaseRegistry: leaseRegistry,
      onFinalized: { [weak self] operation in
        self?.registry.remove(requestId: operation.id, matching: operation)
      },
      completion: completion
    )
    let accepted = lifecycle.withLock { disposed in
      guard !disposed else { return false }
      return registry.addIfAbsent(requestId: request.requestId, request: operation)
    }
    guard accepted else {
      completion(.success(.failure(.cancelled)))
      return
    }
    pool.enqueue(operation: operation) { [weak self, weak operation] permit in
      guard let self, let operation else {
        permit.release()
        return
      }
      guard operation.begin(with: permit) else {
        permit.release()
        return
      }
      self.ioExecutor.execute { [weak self, weak operation] in
        guard let self, let operation, operation.isActive else { return }
        self.start(
          request: request,
          url: url,
          authorization: authorization,
          operation: operation
        )
      }
    }
  }

  private func start(
    request: RemoteOriginalExportRequest,
    url: URL,
    authorization: NetworkOriginAuthorization,
    operation: OriginalExportOperation
  ) {
    guard
      URLSessionManager.allows(url, under: authorization),
      let requestHeaders = URLSessionManager.headers(under: authorization)
    else {
      finish(operation, failure: .wrongServer)
      return
    }
    let destination: OriginalExportDestination
    do {
      destination = try fileStore.createDestination(suggestedName: request.suggestedName)
    } catch let failure as OriginalExportFailure {
      finish(operation, failure: failure)
      return
    } catch {
      finish(operation, failure: .storageUnavailable)
      return
    }
    let writer = OriginalExportLeaseWriter(destination: destination, store: fileStore)
    guard operation.attach(writer: writer) else {
      writer.cleanup()
      return
    }

    var urlRequest = URLRequest(url: url)
    urlRequest.cachePolicy = .reloadIgnoringLocalCacheData
    urlRequest.httpShouldHandleCookies = false
    for (header, value) in requestHeaders
    where header.caseInsensitiveCompare("Cookie") != .orderedSame {
      urlRequest.setValue(value, forHTTPHeaderField: header)
    }
    if let cookieHeader = exactHostCookieHeader(for: url) {
      urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    }
    let task = session.dataTask(with: urlRequest)
    guard operation.beginNativeRequest() else { return }
    sessionDelegate.register(
      task: task,
      operation: operation,
      writer: writer,
      authorization: authorization,
      progress: { [weak self, weak operation] fraction in
        guard let self, let operation, operation.isActive else { return }
        self.progressHandler(
          OriginalExportProgress(requestId: request.requestId, fraction: fraction)
        )
      }
    )
    if operation.attachNativeCancel({ task.cancel() }) {
      task.cancel()
      return
    }
    let timeoutTask = scheduler.schedule(after: timeout) { [weak self, weak operation] in
      guard let self, let operation else { return }
      self.finish(operation, failure: .timeout, cancelNative: true)
    }
    guard operation.attach(timeout: timeoutTask) else {
      timeoutTask.cancel()
      return
    }
    task.resume()
  }

  func cancel(requestId: Int64, completion: @escaping () -> Void = {}) {
    guard let operation = registry.value(requestId: requestId) else {
      completion()
      return
    }
    if operation.isQueued { pool.removeQueued(operation) }
    operation.cancel(after: completion)
  }

  func cancelAll(completion: @escaping () -> Void = {}) {
    let operations = registry.all()
    guard !operations.isEmpty else {
      completion()
      return
    }
    let group = DispatchGroup()
    for operation in operations {
      if operation.isQueued { pool.removeQueued(operation) }
      group.enter()
      operation.cancel(after: group.leave)
    }
    group.notify(queue: .global(qos: .userInitiated), execute: completion)
  }

  func dispose(completion: @escaping () -> Void = {}) {
    let shouldDispose = lifecycle.withLock { disposed in
      guard !disposed else { return false }
      disposed = true
      return true
    }
    guard shouldDispose else {
      completion()
      return
    }
    cancelAll { [session] in
      session.invalidateAndCancel()
      completion()
    }
  }

  fileprivate func nativeCompleted(
    _ operation: OriginalExportOperation,
    failure: OriginalExportFailure?
  ) {
    operation.nativeCompleted(with: failure)
  }

  fileprivate func finish(
    _ operation: OriginalExportOperation,
    failure: OriginalExportFailure,
    cancelNative: Bool = false
  ) {
    operation.fail(failure, cancelNative: cancelNative)
  }

  private func exactHostCookieHeader(for url: URL) -> String? {
    guard let host = url.host?.lowercased(), let cookieStorage else { return nil }
    let cookies =
      cookieStorage.cookies(for: url)?.filter {
        $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
      } ?? []
    return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
  }
}
