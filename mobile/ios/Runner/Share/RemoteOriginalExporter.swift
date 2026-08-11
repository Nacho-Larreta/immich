import Foundation

final class RemoteOriginalExportSessionDelegate: NSObject, URLSessionDataDelegate {
  typealias ChallengeHandler = (
    URLSession,
    URLAuthenticationChallenge,
    URLSessionTask,
    NetworkOriginAuthorization,
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
    requestContext: AuthorizedNetworkRequestContext,
    progress: @escaping (Double) -> Void
  ) {
    state.withLock {
      $0.contexts[task.taskIdentifier] = Context(
        operation: operation,
        writer: writer,
        authorization: requestContext.authorization,
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
    guard let context, let redirectURL = request.url else {
      completionHandler(nil)
      return
    }
    guard URLSessionManager.matchesAuthorizedOrigin(redirectURL, under: context.authorization) else {
      completionHandler(nil)
      owner?.finish(context.operation, failure: .wrongServer, cancelNative: true)
      return
    }
    guard URLSessionManager.allows(redirectURL, under: context.authorization) else {
      completionHandler(nil)
      owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
      return
    }
    guard
      URLSessionManager.performAuthorizedDelivery(
        redirectURL,
        under: context.authorization,
        delivery: {
          completionHandler(request)
          return true
        }
      ) == true
    else {
      completionHandler(nil)
      owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
      return
    }
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
      URLSessionManager.matchesAuthorizedOrigin(responseURL, under: context.authorization)
    else {
      completionHandler(.cancel)
      owner?.finish(context.operation, failure: .wrongServer, cancelNative: true)
      return
    }
    guard URLSessionManager.allows(responseURL, under: context.authorization) else {
      completionHandler(.cancel)
      owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
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
      let admission = URLSessionManager.performAuthorizedDelivery(
        responseURL,
        under: context.authorization,
        delivery: { () -> OriginalExportFailure? in
          do {
            try context.writer.open()
            context.acceptedResponse = true
            context.expectedLength = response.expectedContentLength
            completionHandler(.allow)
            return nil
          } catch let failure as OriginalExportFailure {
            return failure
          } catch {
            return .storageUnavailable
          }
        }
      )
      guard let admission else {
        completionHandler(.cancel)
        self.owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
        return
      }
      if let failure = admission {
        completionHandler(.cancel)
        self.owner?.finish(context.operation, failure: failure, cancelNative: true)
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
    guard let requestURL = dataTask.currentRequest?.url ?? dataTask.originalRequest?.url else {
      owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
      return
    }
    dataTask.suspend()
    let writeCompleted = DispatchSemaphore(value: 0)
    ioExecutor.execute { [weak self, weak context] in
      defer { writeCompleted.signal() }
      guard let self, let context, context.acceptedResponse, context.operation.isActive else {
        return
      }
      let admission = URLSessionManager.performAuthorizedDelivery(
        requestURL,
        under: context.authorization,
        delivery: { () -> OriginalExportFailure? in
          do {
            try context.writer.append(data)
            context.receivedLength += Int64(data.count)
            if context.expectedLength > 0 {
              context.progress(min(1, Double(context.receivedLength) / Double(context.expectedLength)))
            }
            return nil
          } catch {
            return .writeFailed
          }
        }
      )
      guard let admission else {
        self.owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
        return
      }
      if let failure = admission {
        self.owner?.finish(context.operation, failure: failure, cancelNative: true)
      }
    }
    writeCompleted.wait()
    state.withLock { $0.pendingWrites -= 1 }
    guard context.operation.isActive else { return }
    guard
      URLSessionManager.performAuthorizedDelivery(
        requestURL,
        under: context.authorization,
        delivery: {
          dataTask.resume()
          return true
        }
      ) == true
    else {
      owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
      return
    }
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
    guard let requestURL = task.currentRequest?.url ?? task.originalRequest?.url else {
      owner?.nativeCompleted(context.operation, failure: .staleContext)
      return
    }
    let failure: OriginalExportFailure?
    if let error {
      failure = (error as? URLError)?.code == .cancelled ? .cancelled : .serverUnavailable
    } else if context.acceptedResponse, context.receivedLength > 0 {
      failure = nil
    } else {
      failure = .httpFailure
    }
    ioExecutor.execute { [weak self] in
      guard let self else { return }
      self.completeNative(context, requestURL: requestURL, failure: failure)
    }
  }

  private func completeNative(
    _ context: Context,
    requestURL: URL,
    failure: OriginalExportFailure?
  ) {
    guard
      URLSessionManager.performAuthorizedDelivery(
        requestURL,
        under: context.authorization,
        delivery: {
          owner?.nativeCompleted(context.operation, failure: failure)
          return true
        }
      ) == true
    else {
      owner?.nativeCompleted(context.operation, failure: .staleContext)
      return
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
    guard let task, let context = state.withLock({ $0.contexts[task.taskIdentifier] }) else {
      completion(.cancelAuthenticationChallenge, nil)
      return
    }
    guard
      let requestURL = task.currentRequest?.url ?? task.originalRequest?.url,
      URLSessionManager.allows(requestURL, under: context.authorization),
      let challengeHandler
    else {
      completion(.cancelAuthenticationChallenge, nil)
      owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
      return
    }
    challengeHandler(session, challenge, task, context.authorization) {
      [weak self, weak context] disposition, credential in
      guard let context else {
        completion(.cancelAuthenticationChallenge, nil)
        return
      }
      guard URLSessionManager.allows(requestURL, under: context.authorization) else {
        completion(.cancelAuthenticationChallenge, nil)
        self?.owner?.finish(context.operation, failure: .staleContext, cancelNative: true)
        return
      }
      completion(disposition, credential)
    }
  }
}

final class RemoteOriginalExporter: NSObject, @unchecked Sendable {
  // A fixed deadline bounds a stalled NAS response without treating individual slow chunks as activity.
  static let standardTimeout: TimeInterval = 120

  convenience override init() {
    let manager = URLSessionManager.shared
    self.init(
      sessionConfiguration: manager.session.configuration,
      cookieStorage: URLSessionManager.cookieStorage,
      challengeHandler: { session, challenge, task, authorization, completion in
        manager.delegate.handleChallenge(
          session,
          challenge,
          completion,
          task: task,
          authorization: authorization
        )
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
    cookieStorage: HTTPCookieStorage? = nil,
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
    let cookieStorage = cookieStorage ?? configuration.httpCookieStorage
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
    requestContextObserver = NotificationCenter.default.addObserver(
      forName: URLSessionManager.requestContextDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.failStaleOperations()
    }
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
  private var requestContextObserver: NSObjectProtocol?

  var peakPendingWriteCount: Int { sessionDelegate.peakPendingWriteCount }
  var activeCount: Int { pool.activeCount }
  var peakActiveCount: Int { pool.peakActiveCount }
  var usesURLCache: Bool { session.configuration.urlCache != nil }

  func export(
    request: RemoteOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    guard let url = URL(string: request.url) else {
      completion(.success(.failure(.wrongServer)))
      return
    }
    let admission = URLSessionManager.captureOriginalExportRequestContext(
      for: url,
      declaredOrigin: request.origin,
      apiEndpoint: request.apiEndpoint,
      schemePolicy: request.schemePolicy,
      expectedSessionEpoch: request.sessionEpoch,
      expectedGeneration: request.expectedContextGeneration,
      cookieStorage: cookieStorage ?? URLSessionManager.cookieStorage
    )
    let requestContext: AuthorizedNetworkRequestContext
    switch admission {
    case .authorized(let captured): requestContext = captured
    case .staleContext:
      completion(.success(.failure(.staleContext)))
      return
    case .rejected:
      completion(.success(.failure(.wrongServer)))
      return
    }

    let operation = OriginalExportOperation(
      id: request.requestId,
      ioExecutor: ioExecutor,
      leaseRegistry: leaseRegistry,
      successCommitFence: { commit in
        URLSessionManager.performAuthorizedDelivery(
          url,
          under: requestContext.authorization,
          delivery: commit
        )
      },
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
          requestContext: requestContext,
          operation: operation
        )
      }
    }
  }

  private func start(
    request: RemoteOriginalExportRequest,
    url: URL,
    requestContext: AuthorizedNetworkRequestContext,
    operation: OriginalExportOperation
  ) {
    let destinationAdmission = URLSessionManager.performAuthorizedDelivery(
      url,
      under: requestContext.authorization,
      delivery: { () -> Result<OriginalExportDestination, OriginalExportFailure> in
        do {
          return .success(
            try fileStore.createDestination(suggestedName: request.suggestedName)
          )
        } catch let failure as OriginalExportFailure {
          return .failure(failure)
        } catch {
          return .failure(.storageUnavailable)
        }
      }
    )
    guard let destinationAdmission else {
      finish(operation, failure: .staleContext)
      return
    }
    let destination: OriginalExportDestination
    switch destinationAdmission {
    case .success(let created): destination = created
    case .failure(let failure):
      finish(operation, failure: failure)
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
    for (header, value) in requestContext.headers
    where header.caseInsensitiveCompare("Cookie") != .orderedSame {
      urlRequest.setValue(value, forHTTPHeaderField: header)
    }
    if let cookieHeader = requestContext.cookieHeader {
      urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    }
    let task = session.dataTask(with: urlRequest)
    guard operation.beginNativeRequest() else { return }
    sessionDelegate.register(
      task: task,
      operation: operation,
      writer: writer,
      requestContext: requestContext,
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
    guard
      URLSessionManager.performAuthorizedDelivery(
        url,
        under: requestContext.authorization,
        delivery: {
          task.resume()
          return true
        }
      ) == true
    else {
      finish(operation, failure: .staleContext, cancelNative: true)
      return
    }
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

  private func failStaleOperations() {
    for operation in registry.all() {
      if operation.isQueued { pool.removeQueued(operation) }
      finish(operation, failure: .staleContext, cancelNative: true)
    }
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
    if let requestContextObserver {
      NotificationCenter.default.removeObserver(requestContextObserver)
      self.requestContextObserver = nil
    }
    cancelAll { [session] in
      session.invalidateAndCancel()
      completion()
    }
  }

  deinit {
    if let requestContextObserver {
      NotificationCenter.default.removeObserver(requestContextObserver)
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

}
