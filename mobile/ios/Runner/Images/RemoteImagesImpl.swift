import Accelerate
import Flutter
import MobileCoreServices
import Photos

struct RemoteImageCanonicalOrigin: Equatable, Sendable {
  let scheme: String
  let host: String
  let port: Int

  init?(requestURL: URL) {
    guard
      requestURL.user == nil,
      requestURL.password == nil,
      requestURL.fragment == nil,
      let scheme = requestURL.scheme?.lowercased(),
      let host = requestURL.host?.lowercased(),
      let port = Self.effectivePort(scheme: scheme, explicitPort: requestURL.port)
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = port
  }

  init?(origin: String) {
    guard
      let components = URLComponents(string: origin),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      components.percentEncodedPath.isEmpty || components.percentEncodedPath == "/",
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      let port = Self.effectivePort(scheme: scheme, explicitPort: components.port)
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

final class RemoteImageSessionDelegate: NSObject, URLSessionTaskDelegate {
  typealias ChallengeHandler = (
    URLSession,
    URLAuthenticationChallenge,
    URLSessionTask?,
    @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) -> Void

  private struct AuthorizedOrigin: Sendable {
    let origin: RemoteImageCanonicalOrigin
    let authorization: NetworkOriginAuthorization
  }

  private struct State: Sendable {
    var origins: [Int: AuthorizedOrigin] = [:]
    var rejectedRedirects: Set<Int> = []
  }

  private let state = Mutex(State())
  private let challengeHandler: ChallengeHandler?

  init(challengeHandler: ChallengeHandler?) {
    self.challengeHandler = challengeHandler
  }

  func register(
    task: URLSessionTask,
    origin: RemoteImageCanonicalOrigin,
    authorization: NetworkOriginAuthorization
  ) {
    state.withLock {
      $0.origins[task.taskIdentifier] = AuthorizedOrigin(
        origin: origin,
        authorization: authorization
      )
    }
  }

  func consumeRejectedRedirect(for taskIdentifier: Int) -> Bool {
    state.withLock {
      $0.origins.removeValue(forKey: taskIdentifier)
      return $0.rejectedRedirects.remove(taskIdentifier) != nil
    }
  }

  func unregister(taskIdentifier: Int) {
    state.withLock {
      $0.origins.removeValue(forKey: taskIdentifier)
      $0.rejectedRedirects.remove(taskIdentifier)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    let isAllowed = state.withLock { state in
      guard
        let authorizedOrigin = state.origins[task.taskIdentifier],
        let redirectURL = request.url,
        RemoteImageCanonicalOrigin(requestURL: redirectURL) == authorizedOrigin.origin,
        URLSessionManager.allows(redirectURL, under: authorizedOrigin.authorization)
      else {
        state.rejectedRedirects.insert(task.taskIdentifier)
        return false
      }
      return true
    }
    completionHandler(isAllowed ? request : nil)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    handleChallenge(
      session: session, challenge: challenge, task: nil, completion: completionHandler)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    handleChallenge(
      session: session, challenge: challenge, task: task, completion: completionHandler)
  }

  private func handleChallenge(
    session: URLSession,
    challenge: URLAuthenticationChallenge,
    task: URLSessionTask?,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let challengeHandler else {
      return completion(.performDefaultHandling, nil)
    }
    let requestContextIsCurrent = state.withLock { state in
      if let task {
        guard
          let authorizedOrigin = state.origins[task.taskIdentifier],
          let requestURL = task.currentRequest?.url ?? task.originalRequest?.url
        else { return false }
        return URLSessionManager.allows(requestURL, under: authorizedOrigin.authorization)
      }
      return state.origins.values.contains { authorizedOrigin in
        guard
          let originURL = URL(
            string:
              "\(authorizedOrigin.origin.scheme)://\(authorizedOrigin.origin.host):\(authorizedOrigin.origin.port)"
          )
        else { return false }
        return URLSessionManager.allows(originURL, under: authorizedOrigin.authorization)
      }
    }
    guard requestContextIsCurrent else {
      return completion(.cancelAuthenticationChallenge, nil)
    }
    challengeHandler(session, challenge, task, completion)
  }
}

final class RemoteImageOperation: ImageRequest<RemoteImageResult>, @unchecked Sendable {
  private struct State: @unchecked Sendable {
    var task: URLSessionDataTask?
    var interval: (any PerformanceInterval)?
    var isAccepted = false
    var isCancelled = false
    var isCompleted = false
  }

  private let state = Mutex(State())
  let id: Int64
  let requiresRequestContext: Bool

  init(
    id: Int64,
    requiresRequestContext: Bool = true,
    completion: @escaping (Result<RemoteImageResult, any Error>) -> Void
  ) {
    self.id = id
    self.requiresRequestContext = requiresRequestContext
    super.init(completion: completion)
  }

  func markAccepted(
    kind: RemoteImageRequestKind,
    recorder: any PerformanceRecording
  ) {
    let interval = recorder.beginRequest(kind.performanceRequestKind)
    state.withLock { state in
      precondition(!state.isAccepted, "Remote image request accepted more than once")
      state.isAccepted = true
      state.interval = interval
    }
  }

  func start(_ dataTask: URLSessionDataTask) {
    let shouldCancel = state.withLock {
      $0.task = dataTask
      return $0.isCancelled
    }
    if shouldCancel {
      dataTask.cancel()
    } else {
      dataTask.resume()
    }
  }

  var taskIdentifier: Int? {
    state.withLock { $0.task?.taskIdentifier }
  }

  override var isCancelled: Bool {
    state.withLock { $0.isCancelled }
  }

  override func cancel() -> Bool {
    let cancellation: (accepted: Bool, task: URLSessionDataTask?) = state.withLock { state in
      guard !state.isCancelled, !state.isCompleted else { return (false, nil) }
      state.isCancelled = true
      return (true, state.task)
    }
    guard cancellation.accepted else { return false }
    cancellation.task?.cancel()
    _ = complete(.success(RemoteImageResult(payload: nil, error: .cancelled)))
    return true
  }

  override func complete(_ result: Result<RemoteImageResult, any Error>) -> Bool {
    let terminal: (shouldComplete: Bool, interval: (any PerformanceInterval)?) = state.withLock {
      state in
      guard !state.isCompleted else { return (false, nil) }
      state.isCompleted = true
      defer { state.interval = nil }
      return (true, state.interval)
    }
    guard terminal.shouldComplete else { return false }
    terminal.interval?.finish()
    completion(result)
    return true
  }
}

extension RemoteImageRequestKind {
  fileprivate var performanceRequestKind: PerformanceRequestKind {
    switch self {
    case .thumbnail: .remoteThumbnail
    case .original: .remoteOriginal
    }
  }
}

enum RemoteImagePayloadOwnership {
  static func releaseIfUndelivered(
    _ pointer: UnsafeMutableRawPointer,
    delivered: Bool,
    release: (UnsafeMutableRawPointer) -> Void = { free($0) }
  ) {
    guard !delivered else { return }
    release(pointer)
  }
}

class RemoteImageApiImpl: NSObject, RemoteImageApi {
  private let registry = RequestRegistry<RemoteImageOperation>()
  private let sessionDelegate: RemoteImageSessionDelegate
  private let session: URLSession
  private let cookieStorage: HTTPCookieStorage?
  private let urlCache: URLCache?
  private let performanceRecorder: any PerformanceRecording
  private static let rgbaFormat = vImage_CGImageFormat(
    bitsPerComponent: 8,
    bitsPerPixel: 32,
    colorSpace: CGColorSpaceCreateDeviceRGB(),
    bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
    renderingIntent: .perceptual
  )!
  private static let decodeOptions =
    [
      kCGImageSourceShouldCache: false,
      kCGImageSourceShouldCacheImmediately: true,
      kCGImageSourceCreateThumbnailWithTransform: true,
      kCGImageSourceCreateThumbnailFromImageAlways: true,
    ] as CFDictionary

  override convenience init() {
    let manager = URLSessionManager.shared
    self.init(
      sessionConfiguration: manager.session.configuration,
      cookieStorage: URLSessionManager.cookieStorage,
      challengeHandler: { session, challenge, task, completion in
        manager.delegate.handleChallenge(session, challenge, completion, task: task)
      },
      beforeNetworkTaskRegistration: {},
      performanceRecorder: PerformanceTelemetry.shared
    )
  }

  convenience init(
    sessionConfiguration: URLSessionConfiguration,
    beforeNetworkTaskRegistration: @escaping () -> Void = {},
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared
  ) {
    self.init(
      sessionConfiguration: sessionConfiguration,
      cookieStorage: sessionConfiguration.httpCookieStorage,
      challengeHandler: nil,
      beforeNetworkTaskRegistration: beforeNetworkTaskRegistration,
      performanceRecorder: performanceRecorder
    )
  }

  private init(
    sessionConfiguration: URLSessionConfiguration,
    cookieStorage: HTTPCookieStorage?,
    challengeHandler: RemoteImageSessionDelegate.ChallengeHandler?,
    beforeNetworkTaskRegistration: @escaping () -> Void,
    performanceRecorder: any PerformanceRecording
  ) {
    let urlCache = sessionConfiguration.urlCache
    let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
    configuration.urlCache = urlCache
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.httpAdditionalHeaders = nil
    let sessionDelegate = RemoteImageSessionDelegate(challengeHandler: challengeHandler)
    self.cookieStorage = cookieStorage
    self.urlCache = urlCache
    self.beforeNetworkTaskRegistration = beforeNetworkTaskRegistration
    self.performanceRecorder = performanceRecorder
    self.sessionDelegate = sessionDelegate
    self.session = URLSession(
      configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    super.init()
    requestContextObserver = NotificationCenter.default.addObserver(
      forName: URLSessionManager.requestContextDidChange,
      object: nil,
      queue: nil
    ) { [weak self] _ in
      self?.cancelRequestsRequiringContext()
    }
  }

  private var requestContextObserver: NSObjectProtocol?
  private let beforeNetworkTaskRegistration: () -> Void

  func requestImage(
    request input: RemoteImageRequest,
    completion: @escaping (Result<RemoteImageResult, any Error>) -> Void
  ) {
    guard
      let url = URL(string: input.url),
      let requestOrigin = RemoteImageCanonicalOrigin(requestURL: url),
      let declaredOrigin = RemoteImageCanonicalOrigin(origin: input.origin),
      requestOrigin == declaredOrigin
    else {
      return completion(.success(Self.failure(.wrongServer)))
    }

    let request = RemoteImageOperation(
      id: input.requestId,
      requiresRequestContext: input.policy != .cacheOnly,
      completion: completion
    )
    let replacedRequest = registry.add(requestId: input.requestId, request: request)
    request.markAccepted(kind: input.kind, recorder: performanceRecorder)
    _ = replacedRequest?.cancel()

    if input.policy == .cacheOnly {
      var cacheRequest = URLRequest(url: url)
      cacheRequest.cachePolicy = Self.cachePolicy(for: input.policy)
      cacheRequest.httpShouldHandleCookies = false
      if let cookieHeader = exactHostCookieHeader(for: url) {
        cacheRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
      }
      guard let cachedResponse = urlCache?.cachedResponse(for: cacheRequest) else {
        Self.finish(request: request, registry: registry, result: Self.failure(.cacheMiss))
        return
      }
      return Self.handleCompletion(
        request: request,
        registry: registry,
        encoded: input.preferEncoded,
        policy: input.policy,
        data: cachedResponse.data,
        response: cachedResponse.response,
        error: nil,
        rejectedRedirect: false,
        requestContextStillCurrent: true
      )
    }

    guard
      let cookieStorage,
      let requestContext = URLSessionManager.captureRequestContext(
        for: url,
        declaredOrigin: input.origin,
        cookieStorage: cookieStorage
      )
    else {
      Self.finish(request: request, registry: registry, result: Self.failure(.wrongServer))
      return
    }
    var urlRequest = URLRequest(url: url)
    urlRequest.cachePolicy = Self.cachePolicy(for: input.policy)
    urlRequest.httpShouldHandleCookies = false
    for (header, value) in requestContext.headers {
      urlRequest.setValue(value, forHTTPHeaderField: header)
    }
    if let cookieHeader = requestContext.cookieHeader {
      urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    }
    beforeNetworkTaskRegistration()
    guard
      !request.isCancelled,
      URLSessionManager.allows(url, under: requestContext.authorization)
    else {
      if !request.isCancelled {
        Self.finish(request: request, registry: registry, result: Self.failure(.wrongServer))
      }
      return
    }

    let task = session.dataTask(with: urlRequest) { [self, request] data, response, error in
      let rejectedRedirect =
        request.taskIdentifier.map(sessionDelegate.consumeRejectedRedirect) ?? false
      Self.handleCompletion(
        request: request,
        registry: registry,
        encoded: input.preferEncoded,
        policy: input.policy,
        data: data,
        response: response,
        error: error,
        rejectedRedirect: rejectedRedirect,
        requestContextStillCurrent: URLSessionManager.allows(
          url,
          under: requestContext.authorization
        )
      )
    }

    sessionDelegate.register(
      task: task,
      origin: declaredOrigin,
      authorization: requestContext.authorization
    )
    guard
      !request.isCancelled,
      URLSessionManager.allows(url, under: requestContext.authorization)
    else {
      sessionDelegate.unregister(taskIdentifier: task.taskIdentifier)
      task.cancel()
      if !request.isCancelled {
        Self.finish(request: request, registry: registry, result: Self.failure(.wrongServer))
      }
      return
    }
    request.start(task)
  }

  func cancelRequest(requestId: Int64) {
    guard let request = registry.remove(requestId: requestId) else { return }
    if let taskIdentifier = request.taskIdentifier {
      sessionDelegate.unregister(taskIdentifier: taskIdentifier)
    }
    _ = request.cancel()
  }

  func cancelAll() {
    for request in registry.removeAll() {
      if let taskIdentifier = request.taskIdentifier {
        sessionDelegate.unregister(taskIdentifier: taskIdentifier)
      }
      _ = request.cancel()
    }
  }

  private func cancelRequestsRequiringContext() {
    for request in registry.all() where request.requiresRequestContext {
      guard registry.remove(requestId: request.id, matching: request) != nil else { continue }
      if let taskIdentifier = request.taskIdentifier {
        sessionDelegate.unregister(taskIdentifier: taskIdentifier)
      }
      _ = request.cancel()
    }
  }

  func dispose() {
    if let requestContextObserver {
      NotificationCenter.default.removeObserver(requestContextObserver)
      self.requestContextObserver = nil
    }
    cancelAll()
    session.invalidateAndCancel()
  }

  deinit {
    if let requestContextObserver {
      NotificationCenter.default.removeObserver(requestContextObserver)
    }
  }

  func clearCache(
    request: RemoteImageCacheClearRequest,
    completion: @escaping (Result<RemoteImageCacheClearResult, any Error>) -> Void
  ) {
    Task {
      guard let cache = urlCache else {
        return completion(
          .success(
            RemoteImageCacheClearResult(
              clearedBytes: nil,
              error: .cacheMiss
            )
          )
        )
      }
      let cacheSize = Int64(cache.currentDiskUsage)
      cache.removeAllCachedResponses()
      completion(
        .success(
          RemoteImageCacheClearResult(
            clearedBytes: cacheSize,
            error: nil
          )
        )
      )
    }
  }

  private static func handleCompletion(
    request: RemoteImageOperation,
    registry: RequestRegistry<RemoteImageOperation>,
    encoded: Bool,
    policy: RemoteImagePolicy,
    data: Data?,
    response: URLResponse?,
    error: Error?,
    rejectedRedirect: Bool,
    requestContextStillCurrent: Bool
  ) {
    if request.isCancelled {
      finish(request: request, registry: registry, result: failure(.cancelled))
      return
    }

    if rejectedRedirect {
      finish(request: request, registry: registry, result: failure(.wrongServer))
      return
    }

    if !requestContextStillCurrent {
      finish(request: request, registry: registry, result: failure(.wrongServer))
      return
    }

    if error != nil {
      finish(
        request: request,
        registry: registry,
        result: failure(isCacheMiss(policy: policy, error: error) ? .cacheMiss : .serverUnavailable)
      )
      return
    }

    if let response = response as? HTTPURLResponse, !(200..<300).contains(response.statusCode) {
      let error: RemoteImageErrorCode =
        response.statusCode == 401 ? .unauthorized : .serverUnavailable
      finish(request: request, registry: registry, result: failure(error))
      return
    }

    guard let data, !data.isEmpty else {
      finish(request: request, registry: registry, result: failure(.serverUnavailable))
      return
    }

    if encoded {
      return completeEncoded(request: request, registry: registry, data: data)
    }

    completeDecoded(request: request, registry: registry, data: data)
  }

  private static func completeEncoded(
    request: RemoteImageOperation,
    registry: RequestRegistry<RemoteImageOperation>,
    data: Data
  ) {
    let length = data.count
    guard let pointer = malloc(length) else {
      finish(request: request, registry: registry, result: failure(.serverUnavailable))
      return
    }
    data.copyBytes(to: pointer.assumingMemoryBound(to: UInt8.self), count: length)

    if request.isCancelled {
      free(pointer)
      finish(request: request, registry: registry, result: failure(.cancelled))
      return
    }

    let delivered = finish(
      request: request,
      registry: registry,
      result: success(
        RemoteImagePayload(
          pointer: Int64(Int(bitPattern: pointer)),
          length: Int64(length)
        )
      )
    )
    RemoteImagePayloadOwnership.releaseIfUndelivered(pointer, delivered: delivered)
  }

  private static func completeDecoded(
    request: RemoteImageOperation,
    registry: RequestRegistry<RemoteImageOperation>,
    data: Data
  ) {
    ImageProcessing.queue.addOperation {
      if request.isCancelled {
        finish(request: request, registry: registry, result: failure(.cancelled))
        return
      }

      guard
        let imageSource = CGImageSourceCreateWithData(data as CFData, nil),
        let cgImage = CGImageSourceCreateThumbnailAtIndex(
          imageSource,
          0,
          decodeOptions
        )
      else {
        finish(request: request, registry: registry, result: failure(.serverUnavailable))
        return
      }

      do {
        let buffer = try vImage_Buffer(cgImage: cgImage, format: rgbaFormat)
        if request.isCancelled {
          buffer.free()
          finish(request: request, registry: registry, result: failure(.cancelled))
          return
        }

        let delivered = finish(
          request: request,
          registry: registry,
          result: success(
            RemoteImagePayload(
              pointer: Int64(Int(bitPattern: buffer.data)),
              width: Int64(buffer.width),
              height: Int64(buffer.height),
              rowBytes: Int64(buffer.rowBytes)
            )
          )
        )
        RemoteImagePayloadOwnership.releaseIfUndelivered(
          buffer.data,
          delivered: delivered,
          release: { _ in buffer.free() }
        )
      } catch {
        finish(request: request, registry: registry, result: failure(.serverUnavailable))
      }
    }
  }

  @discardableResult
  private static func finish(
    request: RemoteImageOperation,
    registry: RequestRegistry<RemoteImageOperation>,
    result: RemoteImageResult
  ) -> Bool {
    registry.remove(requestId: request.id, matching: request)
    return request.complete(.success(result))
  }

  private static func cachePolicy(for policy: RemoteImagePolicy) -> URLRequest.CachePolicy {
    switch policy {
    case .cacheOnly: return .returnCacheDataDontLoad
    case .cacheThenNetwork: return .returnCacheDataElseLoad
    }
  }

  private func exactHostCookieHeader(for url: URL) -> String? {
    guard let host = url.host?.lowercased(), let cookieStorage else { return nil }
    let cookies =
      cookieStorage.cookies(for: url)?.filter {
        $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
      } ?? []
    return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
  }

  private static func isCacheMiss(policy: RemoteImagePolicy, error: Error?) -> Bool {
    guard policy == .cacheOnly, let error = error as? URLError else { return false }
    return error.code == .resourceUnavailable
  }

  private static func success(_ payload: RemoteImagePayload) -> RemoteImageResult {
    RemoteImageResult(payload: payload, error: nil)
  }

  private static func failure(_ error: RemoteImageErrorCode) -> RemoteImageResult {
    RemoteImageResult(payload: nil, error: error)
  }
}
