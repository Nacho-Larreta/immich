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

  private struct State: Sendable {
    var origins: [Int: RemoteImageCanonicalOrigin] = [:]
    var rejectedRedirects: Set<Int> = []
  }

  private let state = Mutex(State())
  private let challengeHandler: ChallengeHandler?

  init(challengeHandler: ChallengeHandler?) {
    self.challengeHandler = challengeHandler
  }

  func register(task: URLSessionTask, origin: RemoteImageCanonicalOrigin) {
    state.withLock { $0.origins[task.taskIdentifier] = origin }
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
        let expectedOrigin = state.origins[task.taskIdentifier],
        let redirectURL = request.url,
        RemoteImageCanonicalOrigin(requestURL: redirectURL) == expectedOrigin
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
    challengeHandler(session, challenge, task, completion)
  }
}

final class RemoteImageOperation: ImageRequest<RemoteImageResult>, @unchecked Sendable {
  private let task = Mutex<URLSessionDataTask?>(nil)
  let id: Int64

  init(
    id: Int64,
    completion: @escaping (Result<RemoteImageResult, any Error>) -> Void
  ) {
    self.id = id
    super.init(completion: completion)
  }

  func start(_ dataTask: URLSessionDataTask) {
    let shouldCancel = task.withLock {
      $0 = dataTask
      return isCancelled
    }
    if shouldCancel {
      dataTask.cancel()
    } else {
      dataTask.resume()
    }
  }

  var taskIdentifier: Int? {
    task.withLock { $0?.taskIdentifier }
  }

  override func cancel() -> Bool {
    guard super.cancel() else { return false }
    task.withLock { $0?.cancel() }
    complete(.success(RemoteImageResult(payload: nil, error: .cancelled)))
    return true
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
      challengeHandler: { session, challenge, task, completion in
        manager.delegate.handleChallenge(session, challenge, completion, task: task)
      }
    )
  }

  convenience init(sessionConfiguration: URLSessionConfiguration) {
    self.init(sessionConfiguration: sessionConfiguration, challengeHandler: nil)
  }

  private init(
    sessionConfiguration: URLSessionConfiguration,
    challengeHandler: RemoteImageSessionDelegate.ChallengeHandler?
  ) {
    let urlCache = sessionConfiguration.urlCache
    let configuration = sessionConfiguration.copy() as! URLSessionConfiguration
    let cookieStorage = configuration.httpCookieStorage
    configuration.urlCache = urlCache
    configuration.httpShouldSetCookies = false
    configuration.httpCookieStorage = nil
    configuration.httpAdditionalHeaders = configuration.httpAdditionalHeaders?.filter {
      String(describing: $0.key).caseInsensitiveCompare("Cookie") != .orderedSame
    }
    let sessionDelegate = RemoteImageSessionDelegate(challengeHandler: challengeHandler)
    self.cookieStorage = cookieStorage
    self.urlCache = urlCache
    self.sessionDelegate = sessionDelegate
    self.session = URLSession(
      configuration: configuration, delegate: sessionDelegate, delegateQueue: nil)
    super.init()
  }

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

    var urlRequest = URLRequest(url: url)
    urlRequest.cachePolicy = Self.cachePolicy(for: input.policy)
    urlRequest.httpShouldHandleCookies = false
    if let cookieHeader = exactHostCookieHeader(for: url) {
      urlRequest.setValue(cookieHeader, forHTTPHeaderField: "Cookie")
    }

    let request = RemoteImageOperation(id: input.requestId, completion: completion)
    if let replacedRequest = registry.add(requestId: input.requestId, request: request) {
      _ = replacedRequest.cancel()
    }

    if input.policy == .cacheOnly {
      guard let cachedResponse = urlCache?.cachedResponse(for: urlRequest) else {
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
        rejectedRedirect: false
      )
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
        rejectedRedirect: rejectedRedirect
      )
    }

    sessionDelegate.register(task: task, origin: declaredOrigin)
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

  func dispose() {
    cancelAll()
    session.invalidateAndCancel()
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
    rejectedRedirect: Bool
  ) {
    if request.isCancelled {
      finish(request: request, registry: registry, result: failure(.cancelled))
      return
    }

    if rejectedRedirect {
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
