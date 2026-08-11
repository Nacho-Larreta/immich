import Foundation
import background_downloader
import native_video_player

let CLIENT_CERT_LABEL = "com.nacholarreta.nachofotos.client_identity"
let HEADERS_KEY = "immich.request_headers"
let SERVER_URLS_KEY = "immich.server_urls"
let APP_GROUP = "group.com.nacholarreta.nachofotos.share"
let COOKIE_EXPIRY_DAYS: TimeInterval = 400

enum AuthCookie: CaseIterable, Hashable {
  case accessToken, isAuthenticated, authType

  var name: String {
    switch self {
    case .accessToken: return "immich_access_token"
    case .isAuthenticated: return "immich_is_authenticated"
    case .authType: return "immich_auth_type"
    }
  }

  var httpOnly: Bool {
    switch self {
    case .accessToken, .authType: return true
    case .isAuthenticated: return false
    }
  }

  static let names: Set<String> = Set(allCases.map(\.name))
}

struct NetworkCanonicalOrigin: Hashable {
  let scheme: String
  let host: String
  let port: Int

  init?(origin: String) {
    guard
      let components = URLComponents(string: origin),
      components.user == nil,
      components.password == nil,
      components.percentEncodedPath.isEmpty,
      components.query == nil,
      components.fragment == nil,
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      let port = Self.effectivePort(scheme: scheme, explicitPort: components.port)
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = port
  }

  init?(endpoint: String) {
    guard
      let components = URLComponents(string: endpoint),
      components.user == nil,
      components.password == nil,
      components.query == nil,
      components.fragment == nil,
      let scheme = components.scheme?.lowercased(),
      let host = components.host?.lowercased(),
      let port = Self.effectivePort(scheme: scheme, explicitPort: components.port)
    else { return nil }
    self.scheme = scheme
    self.host = host
    self.port = port
  }

  fileprivate init(authorization: NetworkOriginAuthorization) {
    scheme = authorization.scheme
    host = authorization.host
    port = authorization.port
  }

  init?(protectionSpace: URLProtectionSpace) {
    guard
      let scheme = protectionSpace.protocol?.lowercased(),
      let port = Self.effectivePort(
        scheme: scheme,
        explicitPort: protectionSpace.port > 0 ? protectionSpace.port : nil
      )
    else { return nil }
    self.scheme = scheme
    host = protectionSpace.host.lowercased()
    self.port = port
  }

  func matches(_ url: URL) -> Bool {
    guard
      url.user == nil,
      url.password == nil,
      let scheme = url.scheme?.lowercased(),
      let host = url.host?.lowercased(),
      let port = Self.effectivePort(scheme: scheme, explicitPort: url.port)
    else { return false }
    return scheme == self.scheme && host == self.host && port == self.port
  }

  var string: String {
    var components = URLComponents()
    components.scheme = scheme
    components.host = host
    let defaultPort = scheme == "https" ? 443 : 80
    components.port = port == defaultPort ? nil : port
    return components.string!
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

struct NetworkOriginAuthorization: Equatable, Sendable {
  fileprivate let scheme: String
  fileprivate let host: String
  fileprivate let port: Int
  fileprivate let sessionEpoch: Int64
  fileprivate let requestContextRevision: UInt64
}

struct AuthorizedNetworkRequestContext: Equatable, Sendable {
  let authorization: NetworkOriginAuthorization
  let headers: [String: String]
  let cookieHeader: String?
}

enum OriginalExportRequestContextAdmission {
  case authorized(AuthorizedNetworkRequestContext)
  case staleContext
  case rejected
}

struct CookieReconciliationReport: Equatable {
  let iterations: Int
  let writes: Int
}

extension UserDefaults {
  static let group = UserDefaults(suiteName: APP_GROUP)!
}

/// Manages a shared URLSession with SSL configuration support.
/// Old sessions are kept alive by Dart's FFI retain until all isolates release them.
class URLSessionManager: NSObject {
  static let requestContextDidChange = Notification.Name(
    "com.nacholarreta.nachofotos.request-context-did-change"
  )
  static let shared = URLSessionManager()
  private static weak var liveInstance: URLSessionManager?

  private(set) var session: URLSession
  private(set) var delegate: URLSessionManagerDelegate
  private static let cacheDir: URL = {
    let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)
      .first!
      .appendingPathComponent("api", isDirectory: true)
    try! FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
  }()
  private static let urlCache = URLCache(
    memoryCapacity: 0,
    diskCapacity: 1024 * 1024 * 1024,
    directory: cacheDir
  )
  static let userAgent: String = {
    let version =
      Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    return "immich-ios/\(version)"
  }()
  static let cookieStorage = HTTPCookieStorage.sharedCookieStorage(
    forGroupContainerIdentifier: APP_GROUP)
  private static var serverUrls: [String] = []
  private static var activeCanonicalOrigins: [NetworkCanonicalOrigin] = []
  private static var activeAuthCookieValues: [AuthCookie: String] = [:]
  private static var activeHeaders: [String: String] = [:]
  private static var sensitiveHeaderNames: Set<String> = ["authorization", "cookie"]
  private static var requestContextRevision: UInt64 = 0
  private static var requestContextSessionEpoch: Int64 = 0
  private static var requestContextConfirmed = false
  private static var isReplacingRequestContext = false
  private static var cookieReconciliationScheduled = false
  private static var cookieReconciliationRunning = false
  private static var cookieReconciliationDirty = false
  private static var cookieReconciliationWaiters: [(CookieReconciliationReport) -> Void] = []
  private static var lastCookieReconciliationReport = CookieReconciliationReport(
    iterations: 0, writes: 0)
  private static let maximumCookieReconciliationIterations = 8
  private static let cookieReconciliationQueue = DispatchQueue(
    label: "com.nacholarreta.nachofotos.auth-cookie-reconciliation"
  )
  private static let requestContextLock = NSRecursiveLock()
  private static let terminalDeliveryGroup = DispatchGroup()
  private static let sessionTransitionLock = NSLock()
  private static let sessionInvalidationTimeout: DispatchTimeInterval = .seconds(5)
  private static var sessionInvalidationBarrierOverride: (() -> Bool)?

  var sessionPointer: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(session).toOpaque()
  }

  private override init() {
    delegate = URLSessionManagerDelegate()
    Self.initializeBlockedRequestContext()
    session = Self.buildSession(delegate: delegate)
    super.init()
    Self.liveInstance = self
    NotificationCenter.default.addObserver(
      Self.self,
      selector: #selector(Self.cookiesDidChange),
      name: NSNotification.Name.NSHTTPCookieManagerCookiesChanged,
      object: Self.cookieStorage
    )
  }

  static func initializeBlockedRequestContext() {
    var shouldNotify = false
    sessionTransitionLock.withLock {
      withRequestContextLock {
        isReplacingRequestContext = true
        requestContextConfirmed = false
      }
      shouldNotify = true
      guard liveInstance?.invalidateCurrentSession() ?? true else { return }
      withRequestContextLock {
        serverUrls = []
        activeCanonicalOrigins = []
        activeAuthCookieValues = [:]
        activeHeaders = [:]
        let persistedHeaders =
          UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String] ?? [:]
        sensitiveHeaderNames.formUnion(persistedHeaders.keys.map { $0.lowercased() })
        cookieReconciliationDirty = false
        UserDefaults.group.removeObject(forKey: SERVER_URLS_KEY)
        UserDefaults.group.removeObject(forKey: HEADERS_KEY)
        clearAllManagedAuthCookiesLocked()
        requestContextRevision &+= 1
        isReplacingRequestContext = false
      }
      liveInstance?.installCurrentSession()
    }
    if shouldNotify {
      notifyRequestContextDidChange()
    }
  }

  func recreateSession(protocolClasses: [AnyClass]? = nil) {
    guard invalidateCurrentSession() else { return }
    installCurrentSession(protocolClasses: protocolClasses)
  }

  static func replaceRequestContext(
    headers: [String: String],
    canonicalOrigin: String?,
    token: String?,
    sessionEpoch: Int64 = 0
  ) throws {
    guard sessionEpoch >= 0 else { throw NetworkContextError.invalidSessionEpoch }
    _ = shared
    let origin = try validateContext(
      headers: headers, canonicalOrigin: canonicalOrigin, token: token)
    try transitionRequestContext(
      headers: headers,
      origins: origin.map { [$0] } ?? [],
      token: token,
      sessionEpoch: sessionEpoch
    )
  }

  static func failClosedRequestContext() throws {
    _ = shared
    let sessionEpoch = withRequestContextLock { requestContextSessionEpoch }
    try transitionRequestContext(
      headers: [:],
      origins: [],
      token: nil,
      sessionEpoch: sessionEpoch,
      confirmed: false
    )
  }

  static func requestContextSnapshot() -> (
    clientPointer: UnsafeMutableRawPointer,
    canonicalOrigin: String?,
    sessionEpoch: Int64,
    generation: UInt64,
    confirmed: Bool
  ) {
    let manager = shared
    return sessionTransitionLock.withLock {
      let clientPointer = retainedPointer(to: manager.session)
      return withRequestContextLock {
        (
          clientPointer,
          activeCanonicalOrigins.first?.string,
          requestContextSessionEpoch,
          requestContextRevision,
          requestContextConfirmed && !isReplacingRequestContext
        )
      }
    }
  }

  static func requestContextIdentity() -> (sessionEpoch: Int64, generation: Int64) {
    withRequestContextLock {
      (requestContextSessionEpoch, Int64(clamping: requestContextRevision))
    }
  }

  static func retainedPointer<T: AnyObject>(to object: T) -> UnsafeMutableRawPointer {
    Unmanaged.passRetained(object).toOpaque()
  }

  static func replaceLegacyRequestContext(
    headers: [String: String], serverUrls: [String], token: String?
  ) throws {
    _ = shared
    guard serverUrls.count <= 1 else { throw NetworkContextError.multipleOriginsNotAllowed }
    let origins = serverUrls.compactMap(NetworkCanonicalOrigin.init(endpoint:))
    guard origins.count == serverUrls.count else {
      throw NetworkContextError.invalidCanonicalOrigin
    }
    if token != nil && origins.isEmpty { throw NetworkContextError.tokenWithoutOrigin }
    if origins.isEmpty && !headers.isEmpty { throw NetworkContextError.headersWithoutOrigin }
    let sessionEpoch = withRequestContextLock { requestContextSessionEpoch }
    try transitionRequestContext(
      headers: headers,
      origins: origins,
      token: token,
      sessionEpoch: sessionEpoch
    )
  }

  static func allows(_ url: URL) -> Bool {
    withRequestContextLock {
      !isReplacingRequestContext && !activeCanonicalOrigins.isEmpty
        && activeCanonicalOrigins.contains { $0.matches(url) }
    }
  }

  static func authorize(
    _ url: URL,
    declaredOrigin: String
  ) -> NetworkOriginAuthorization? {
    guard let declared = NetworkCanonicalOrigin(origin: declaredOrigin) else { return nil }
    return withRequestContextLock {
      guard
        !isReplacingRequestContext,
        activeCanonicalOrigins.contains(declared),
        declared.matches(url)
      else { return nil }
      return NetworkOriginAuthorization(
        scheme: declared.scheme,
        host: declared.host,
        port: declared.port,
        sessionEpoch: requestContextSessionEpoch,
        requestContextRevision: requestContextRevision
      )
    }
  }

  static func allows(
    _ url: URL,
    under authorization: NetworkOriginAuthorization
  ) -> Bool {
    return withRequestContextLock {
      allowsLocked(url, under: authorization)
    }
  }

  static func matchesAuthorizedOrigin(
    _ url: URL,
    under authorization: NetworkOriginAuthorization
  ) -> Bool {
    NetworkCanonicalOrigin(authorization: authorization).matches(url)
  }

  static func performAuthorizedDelivery<T>(
    _ url: URL,
    under authorization: NetworkOriginAuthorization,
    delivery: () -> T
  ) -> T? {
    let admitted = withRequestContextLock { () -> Bool in
      guard allowsLocked(url, under: authorization) else { return false }
      terminalDeliveryGroup.enter()
      return true
    }
    guard admitted else { return nil }
    defer { terminalDeliveryGroup.leave() }
    return delivery()
  }

  static func captureCacheReadAuthorization(
    for url: URL,
    declaredOrigin: String,
    expectedGeneration: Int64
  ) -> NetworkOriginAuthorization? {
    guard expectedGeneration >= 0, let generation = UInt64(exactly: expectedGeneration) else {
      return nil
    }
    guard let declared = NetworkCanonicalOrigin(origin: declaredOrigin) else { return nil }
    return withRequestContextLock {
      guard
        requestContextConfirmed,
        !isReplacingRequestContext,
        generation == requestContextRevision,
        activeCanonicalOrigins.contains(declared),
        declared.matches(url)
      else { return nil }
      return NetworkOriginAuthorization(
        scheme: declared.scheme,
        host: declared.host,
        port: declared.port,
        sessionEpoch: requestContextSessionEpoch,
        requestContextRevision: requestContextRevision
      )
    }
  }

  static func allowsProtectionSpace(_ protectionSpace: URLProtectionSpace) -> Bool {
    guard let origin = NetworkCanonicalOrigin(protectionSpace: protectionSpace) else {
      return false
    }
    return withRequestContextLock {
      !isReplacingRequestContext && activeCanonicalOrigins.contains(origin)
    }
  }

  static func allowsProtectionSpace(
    _ protectionSpace: URLProtectionSpace,
    under authorization: NetworkOriginAuthorization
  ) -> Bool {
    guard let origin = NetworkCanonicalOrigin(protectionSpace: protectionSpace) else {
      return false
    }
    return withRequestContextLock {
      !isReplacingRequestContext
        && authorization.sessionEpoch == requestContextSessionEpoch
        && authorization.requestContextRevision == requestContextRevision
        && origin == NetworkCanonicalOrigin(authorization: authorization)
        && activeCanonicalOrigins.contains(origin)
    }
  }

  static func headers(
    under authorization: NetworkOriginAuthorization
  ) -> [String: String]? {
    let authorizedOrigin = NetworkCanonicalOrigin(authorization: authorization)
    return withRequestContextLock {
      guard
        !isReplacingRequestContext,
        authorization.sessionEpoch == requestContextSessionEpoch,
        authorization.requestContextRevision == requestContextRevision,
        activeCanonicalOrigins.contains(authorizedOrigin)
      else { return nil }
      var headers = activeHeaders
      headers["User-Agent"] = headers["User-Agent"] ?? userAgent
      return headers
    }
  }

  static func captureRequestContext(
    for url: URL,
    declaredOrigin: String,
    expectedGeneration: Int64,
    cookieStorage: HTTPCookieStorage
  ) -> AuthorizedNetworkRequestContext? {
    guard expectedGeneration >= 0, let generation = UInt64(exactly: expectedGeneration) else {
      return nil
    }
    guard let declared = NetworkCanonicalOrigin(origin: declaredOrigin) else { return nil }
    return withRequestContextLock {
      guard
        requestContextConfirmed,
        !isReplacingRequestContext,
        generation == requestContextRevision,
        activeCanonicalOrigins.contains(declared),
        declared.matches(url)
      else { return nil }
      let authorization = NetworkOriginAuthorization(
        scheme: declared.scheme,
        host: declared.host,
        port: declared.port,
        sessionEpoch: requestContextSessionEpoch,
        requestContextRevision: requestContextRevision
      )
      var headers = activeHeaders
      for key in Array(headers.keys)
      where key.caseInsensitiveCompare("Cookie") == .orderedSame {
        headers.removeValue(forKey: key)
      }
      headers["User-Agent"] = headers["User-Agent"] ?? userAgent
      return AuthorizedNetworkRequestContext(
        authorization: authorization,
        headers: headers,
        cookieHeader: exactHostCookieHeaderLocked(for: url, cookieStorage: cookieStorage)
      )
    }
  }

  static func captureOriginalExportRequestContext(
    for url: URL,
    declaredOrigin: String,
    apiEndpoint: String,
    schemePolicy: OriginalExportSchemePolicy,
    expectedSessionEpoch: Int64,
    expectedGeneration: Int64,
    cookieStorage: HTTPCookieStorage
  ) -> OriginalExportRequestContextAdmission {
    guard
      expectedSessionEpoch >= 0,
      expectedGeneration >= 0,
      let generation = UInt64(exactly: expectedGeneration),
      let declared = NetworkCanonicalOrigin(origin: declaredOrigin),
      let endpointURL = URL(string: apiEndpoint),
      let endpointOrigin = NetworkCanonicalOrigin(endpoint: apiEndpoint),
      endpointOrigin == declared,
      declared.matches(url),
      declared.matches(endpointURL),
      originalExportSchemeIsValid(declared.scheme, policy: schemePolicy),
      url.path.hasPrefix(endpointURL.path.hasSuffix("/") ? endpointURL.path : "\(endpointURL.path)/")
    else { return .rejected }

    return withRequestContextLock {
      guard
        requestContextConfirmed,
        !isReplacingRequestContext,
        expectedSessionEpoch == requestContextSessionEpoch,
        generation == requestContextRevision
      else { return .staleContext }
      guard activeCanonicalOrigins.contains(declared) else { return .rejected }
      let authorization = NetworkOriginAuthorization(
        scheme: declared.scheme,
        host: declared.host,
        port: declared.port,
        sessionEpoch: requestContextSessionEpoch,
        requestContextRevision: requestContextRevision
      )
      var headers = activeHeaders
      for key in Array(headers.keys)
      where key.caseInsensitiveCompare("Cookie") == .orderedSame {
        headers.removeValue(forKey: key)
      }
      headers["User-Agent"] = headers["User-Agent"] ?? userAgent
      return .authorized(
        AuthorizedNetworkRequestContext(
          authorization: authorization,
          headers: headers,
          cookieHeader: exactHostCookieHeaderLocked(for: url, cookieStorage: cookieStorage)
        )
      )
    }
  }

  private static func originalExportSchemeIsValid(
    _ scheme: String,
    policy: OriginalExportSchemePolicy
  ) -> Bool {
    switch policy {
    case .httpsOnly: return scheme == "https"
    case .explicitlyApprovedHttp, .registeredLocalHttp: return scheme == "http"
    }
  }

  private static func validateContext(
    headers: [String: String],
    canonicalOrigin: String?,
    token: String?
  ) throws -> NetworkCanonicalOrigin? {
    guard let canonicalOrigin else {
      if token != nil { throw NetworkContextError.tokenWithoutOrigin }
      if !headers.isEmpty { throw NetworkContextError.headersWithoutOrigin }
      return nil
    }
    guard let origin = NetworkCanonicalOrigin(origin: canonicalOrigin) else {
      throw NetworkContextError.invalidCanonicalOrigin
    }
    return origin
  }

  private static func replaceRequestContextLocked(
    headers: [String: String],
    origins: [NetworkCanonicalOrigin],
    token: String?,
    sessionEpoch: Int64,
    confirmed: Bool = true
  ) {
    let replacedOrigins = Array(Set(activeCanonicalOrigins + origins))
    clearManagedAuthCookiesLocked(for: replacedOrigins)
    sensitiveHeaderNames.formUnion(headers.keys.map { $0.lowercased() })
    activeCanonicalOrigins = origins
    activeAuthCookieValues = authCookieValues(token: token)
    serverUrls = origins.map(\.string)
    UserDefaults.group.set(serverUrls, forKey: SERVER_URLS_KEY)
    _ = reconcileAuthCookiesLocked(origins: origins)
    installHeadersLocked(headers)
    requestContextSessionEpoch = sessionEpoch
    requestContextConfirmed = confirmed
    isReplacingRequestContext = false
  }

  private static func transitionRequestContext(
    headers: [String: String],
    origins: [NetworkCanonicalOrigin],
    token: String?,
    sessionEpoch: Int64,
    confirmed: Bool = true
  ) throws {
    var shouldNotify = false
    do {
      try sessionTransitionLock.withLock {
        let matchesActiveContext = withRequestContextLock {
          requestContextMatchesLocked(
            headers: headers,
            origins: origins,
            token: token,
            sessionEpoch: sessionEpoch,
            confirmed: confirmed
          )
        }
        if matchesActiveContext {
          return
        }

        withRequestContextLock {
          isReplacingRequestContext = true
          requestContextConfirmed = false
        }
        shouldNotify = true
        guard terminalDeliveryGroup.wait(timeout: .now() + sessionInvalidationTimeout) == .success
        else { throw NetworkContextError.sessionInvalidationTimedOut }
        guard shared.invalidateCurrentSession() else {
          withRequestContextLock {
            replaceRequestContextLocked(
              headers: [:],
              origins: [],
              token: nil,
              sessionEpoch: requestContextSessionEpoch,
              confirmed: false
            )
          }
          shared.installCurrentSession()
          throw NetworkContextError.sessionInvalidationTimedOut
        }
        withRequestContextLock {
          replaceRequestContextLocked(
            headers: headers,
            origins: origins,
            token: token,
            sessionEpoch: sessionEpoch,
            confirmed: confirmed
          )
        }
        shared.installCurrentSession()
      }
    } catch {
      if shouldNotify {
        notifyRequestContextDidChange()
      }
      throw error
    }
    if shouldNotify {
      notifyRequestContextDidChange()
    }
  }

  private static func requestContextMatchesLocked(
    headers: [String: String],
    origins: [NetworkCanonicalOrigin],
    token: String?,
    sessionEpoch: Int64,
    confirmed: Bool
  ) -> Bool {
    guard requestContextConfirmed == confirmed,
      requestContextSessionEpoch == sessionEpoch,
      !isReplacingRequestContext,
      activeCanonicalOrigins == origins,
      activeAuthCookieValues[.accessToken] == token,
      let activeCanonicalHeaders = canonicalHeaders(activeHeaders),
      let requestedCanonicalHeaders = canonicalHeaders(headers)
    else { return false }
    return activeCanonicalHeaders == requestedCanonicalHeaders
  }

  private static func canonicalHeaders(_ headers: [String: String]) -> [String: String]? {
    var canonical: [String: String] = [:]
    for (name, value) in headers {
      let canonicalName = name.lowercased()
      if let existing = canonical[canonicalName], existing != value {
        return nil
      }
      canonical[canonicalName] = value
    }
    return canonical
  }

  private static func clearManagedAuthCookiesLocked(for origins: [NetworkCanonicalOrigin]) {
    for cookie in cookieStorage.cookies ?? []
    where AuthCookie.names.contains(cookie.name)
      && origins.contains(where: { cookieDomain(cookie.domain, appliesTo: $0.host) })
    {
      cookieStorage.deleteCookie(cookie)
    }
  }

  private static func clearAllManagedAuthCookiesLocked() {
    for cookie in cookieStorage.cookies ?? [] where AuthCookie.names.contains(cookie.name) {
      cookieStorage.deleteCookie(cookie)
    }
  }

  private static func cookieDomain(_ rawDomain: String, appliesTo host: String) -> Bool {
    let domain = rawDomain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
    return host == domain || host.hasSuffix(".\(domain)")
  }

  private static func authCookieValues(token: String?) -> [AuthCookie: String] {
    guard let token else { return [:] }
    return [
      .accessToken: token,
      .isAuthenticated: "true",
      .authType: "password",
    ]
  }

  @discardableResult
  private static func reconcileAuthCookiesLocked(origins: [NetworkCanonicalOrigin]) -> Int {
    var writes = 0
    let expiry = Date().addingTimeInterval(COOKIE_EXPIRY_DAYS * 24 * 60 * 60)
    for origin in origins {
      for authCookie in AuthCookie.allCases {
        let applicableCookies = applicableAuthCookies(for: origin, named: authCookie.name)
        let expectedValue = activeAuthCookieValues[authCookie]
        let canonicalCookieIndex = expectedValue.flatMap { value in
          applicableCookies.firstIndex {
            isCanonicalAuthCookie(
              $0,
              expectedValue: value,
              authCookie: authCookie,
              origin: origin
            )
          }
        }
        for (index, staleCookie) in applicableCookies.enumerated()
        where index != canonicalCookieIndex {
          cookieStorage.deleteCookie(staleCookie)
          writes += 1
        }
        guard canonicalCookieIndex == nil, let expectedValue else { continue }
        var properties: [HTTPCookiePropertyKey: Any] = [
          .name: authCookie.name,
          .value: expectedValue,
          .domain: origin.host,
          .path: "/",
          .port: String(origin.port),
          .expires: expiry,
        ]
        if origin.scheme == "https" { properties[.secure] = "TRUE" }
        if authCookie.httpOnly { properties[.init("HttpOnly")] = "TRUE" }
        if let httpCookie = HTTPCookie(properties: properties) {
          cookieStorage.setCookie(httpCookie)
          writes += 1
        }
      }
    }
    return writes
  }

  private static func installHeadersLocked(_ headers: [String: String]) {
    activeHeaders = headers
    requestContextRevision &+= 1
    UserDefaults.group.set(headers, forKey: HEADERS_KEY)
  }

  private func invalidateCurrentSession() -> Bool {
    if let override = Self.withRequestContextLock({ Self.sessionInvalidationBarrierOverride }) {
      return override()
    }
    return delegate.invalidateAndWait(
      session,
      timeout: Self.sessionInvalidationTimeout
    )
  }

  private func installCurrentSession(protocolClasses: [AnyClass]? = nil) {
    let replacementDelegate = URLSessionManagerDelegate()
    let replacementSession = Self.buildSession(
      delegate: replacementDelegate,
      protocolClasses: protocolClasses
    )
    delegate = replacementDelegate
    session = replacementSession
  }

  static func overrideSessionInvalidationBarrierForTesting(
    _ barrier: (() -> Bool)?
  ) {
    withRequestContextLock { sessionInvalidationBarrierOverride = barrier }
  }

  private static func withRequestContextLock<T>(_ body: () throws -> T) rethrows -> T {
    requestContextLock.lock()
    defer { requestContextLock.unlock() }
    return try body()
  }

  private static func allowsLocked(
    _ url: URL,
    under authorization: NetworkOriginAuthorization
  ) -> Bool {
    let authorizedOrigin = NetworkCanonicalOrigin(authorization: authorization)
    return requestContextConfirmed && !isReplacingRequestContext
      && authorization.sessionEpoch == requestContextSessionEpoch
      && authorization.requestContextRevision == requestContextRevision
      && activeCanonicalOrigins.contains(authorizedOrigin)
      && authorizedOrigin.matches(url)
  }

  private static func notifyRequestContextDidChange() {
    BackgroundDownloaderRequestContextBridge.contextDidChange()
    NotificationCenter.default.post(name: requestContextDidChange, object: nil)
  }

  @objc private static func cookiesDidChange(_ notification: Notification) {
    withRequestContextLock {
      guard !isReplacingRequestContext, !activeCanonicalOrigins.isEmpty else { return }
      cookieReconciliationDirty = true
      scheduleAuthCookieReconciliationLocked()
    }
  }

  private static func scheduleAuthCookieReconciliationLocked() {
    guard !cookieReconciliationScheduled, !cookieReconciliationRunning else { return }
    cookieReconciliationScheduled = true
    cookieReconciliationQueue.async { runCookieReconciliation() }
  }

  private static func runCookieReconciliation() {
    withRequestContextLock {
      cookieReconciliationScheduled = false
      guard !isReplacingRequestContext, !activeCanonicalOrigins.isEmpty else {
        cookieReconciliationDirty = false
        completeCookieReconciliationWaitersLocked()
        return
      }

      cookieReconciliationRunning = true
      var stableReads = 0
      var iterations = 0
      var writes = 0
      while stableReads < 2 && iterations < maximumCookieReconciliationIterations {
        cookieReconciliationDirty = false
        let iterationWrites = reconcileAuthCookiesLocked(origins: activeCanonicalOrigins)
        writes += iterationWrites
        iterations += 1
        if iterationWrites == 0 && !cookieReconciliationDirty {
          stableReads += 1
        } else {
          stableReads = 0
        }
      }
      cookieReconciliationRunning = false
      lastCookieReconciliationReport = CookieReconciliationReport(
        iterations: iterations,
        writes: writes
      )

      if cookieReconciliationDirty {
        scheduleAuthCookieReconciliationLocked()
      } else {
        completeCookieReconciliationWaitersLocked()
      }
    }
  }

  static func notifyWhenCookieReconciliationIsQuiescent(
    _ completion: @escaping (CookieReconciliationReport) -> Void
  ) {
    cookieReconciliationQueue.async {
      withRequestContextLock {
        if cookieReconciliationScheduled
          || cookieReconciliationRunning
          || cookieReconciliationDirty
        {
          cookieReconciliationWaiters.append(completion)
        } else {
          completion(lastCookieReconciliationReport)
        }
      }
    }
  }

  private static func completeCookieReconciliationWaitersLocked() {
    let waiters = cookieReconciliationWaiters
    cookieReconciliationWaiters.removeAll()
    for waiter in waiters {
      waiter(lastCookieReconciliationReport)
    }
  }

  private static func applicableAuthCookies(
    for origin: NetworkCanonicalOrigin,
    named name: String
  ) -> [HTTPCookie] {
    (cookieStorage.cookies ?? []).filter {
      $0.name == name && cookieDomain($0.domain, appliesTo: origin.host)
    }
  }

  private static func isCanonicalAuthCookie(
    _ cookie: HTTPCookie,
    expectedValue: String,
    authCookie: AuthCookie,
    origin: NetworkCanonicalOrigin
  ) -> Bool {
    cookie.domain.lowercased() == origin.host
      && cookie.path == "/"
      && cookie.value == expectedValue
      && cookie.portList == [NSNumber(value: origin.port)]
      && cookie.isSecure == (origin.scheme == "https")
      && cookie.isHTTPOnly == authCookie.httpOnly
      && (cookie.expiresDate.map { $0 > Date() } ?? false)
  }

  private static func buildSession(
    delegate: URLSessionManagerDelegate,
    protocolClasses: [AnyClass]? = nil
  ) -> URLSession {
    let config = URLSessionConfiguration.default
    config.urlCache = urlCache
    config.httpMaximumConnectionsPerHost = 64
    config.timeoutIntervalForRequest = 60
    config.protocolClasses = protocolClasses
    configureRequestContext(on: config)
    let binding = withRequestContextLock { () -> NetworkOriginAuthorization? in
      guard !isReplacingRequestContext, let origin = activeCanonicalOrigins.first else {
        return nil
      }
      var headers = activeHeaders
      headers["User-Agent"] = headers["User-Agent"] ?? userAgent
      if let cookieHeader = authenticationCookieHeaderLocked() {
        headers["Cookie"] = cookieHeader
      }
      config.httpAdditionalHeaders = headers
      return NetworkOriginAuthorization(
        scheme: origin.scheme,
        host: origin.host,
        port: origin.port,
        sessionEpoch: requestContextSessionEpoch,
        requestContextRevision: requestContextRevision
      )
    }
    let session = URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
    delegate.bind(session, to: binding)
    return session
  }

  static func configureRequestContext(
    on config: URLSessionConfiguration,
    keepCookieStorageBoundWhenBlocked: Bool = false
  ) {
    config.httpShouldSetCookies = false
    config.httpCookieStorage = nil
    config.httpAdditionalHeaders = ["User-Agent": userAgent]
  }

  private static func authenticationCookieHeaderLocked() -> String? {
    let values = AuthCookie.allCases.compactMap { cookie -> String? in
      guard let value = activeAuthCookieValues[cookie] else { return nil }
      return "\(cookie.name)=\(value)"
    }
    return values.isEmpty ? nil : values.joined(separator: "; ")
  }

  private static func exactHostCookieHeaderLocked(
    for url: URL,
    cookieStorage: HTTPCookieStorage
  ) -> String? {
    guard let host = url.host?.lowercased() else { return nil }
    let cookies =
      cookieStorage.cookies(for: url)?.filter {
        $0.domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: ".")) == host
      } ?? []
    return HTTPCookie.requestHeaderFields(with: cookies)["Cookie"]
  }

  /// Patches background_downloader's URLSession to use shared auth configuration.
  /// Must be called before background_downloader creates its session (i.e. early in app startup).
  static func patchBackgroundDownloader() {
    BackgroundDownloaderRequestContextBridge.install(
      capture: captureBackgroundRequestContext,
      isCurrent: isBackgroundRequestContextCurrent,
      challengeHandler: { session, challenge, task, completion in
        URLSessionManager.shared.delegate.handleChallenge(
          session,
          challenge,
          completion,
          task: task,
          requestContextValidated: true
        )
      }
    )
  }

  private static func captureBackgroundRequestContext(
    for url: URL
  ) -> BackgroundDownloaderRequestContextSnapshot? {
    withRequestContextLock {
      guard
        !isReplacingRequestContext,
        activeCanonicalOrigins.contains(where: { $0.matches(url) })
      else { return nil }
      var headers = activeHeaders
      for key in Array(headers.keys)
      where key.caseInsensitiveCompare("Cookie") == .orderedSame {
        headers.removeValue(forKey: key)
      }
      headers["User-Agent"] = headers["User-Agent"] ?? userAgent
      return BackgroundDownloaderRequestContextSnapshot(
        revision: requestContextRevision,
        headers: headers,
        cookieHeader: exactHostCookieHeaderLocked(for: url, cookieStorage: cookieStorage),
        sensitiveHeaderNames: sensitiveHeaderNames
      )
    }
  }

  private static func isBackgroundRequestContextCurrent(
    _ revision: UInt64,
    _ url: URL
  ) -> Bool {
    withRequestContextLock {
      !isReplacingRequestContext
        && revision == requestContextRevision
        && activeCanonicalOrigins.contains(where: { $0.matches(url) })
    }
  }
}

enum NetworkContextError: Error {
  case invalidSessionEpoch
  case invalidCanonicalOrigin
  case tokenWithoutOrigin
  case headersWithoutOrigin
  case multipleOriginsNotAllowed
  case sessionInvalidationTimedOut
}

class URLSessionManagerDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
  private let bindingsLock = NSLock()
  private var sessionBindings: [ObjectIdentifier: NetworkOriginAuthorization] = [:]
  private var invalidationWaiters: [ObjectIdentifier: DispatchSemaphore] = [:]

  func bind(_ session: URLSession, to authorization: NetworkOriginAuthorization?) {
    bindingsLock.withLock {
      let identifier = ObjectIdentifier(session)
      if let authorization {
        sessionBindings[identifier] = authorization
      } else {
        sessionBindings.removeValue(forKey: identifier)
      }
    }
  }

  func invalidateAndWait(
    _ session: URLSession,
    timeout: DispatchTimeInterval
  ) -> Bool {
    let identifier = ObjectIdentifier(session)
    let invalidated = DispatchSemaphore(value: 0)
    bindingsLock.withLock { invalidationWaiters[identifier] = invalidated }
    session.invalidateAndCancel()
    guard invalidated.wait(timeout: .now() + timeout) == .success else {
      _ = bindingsLock.withLock { invalidationWaiters.removeValue(forKey: identifier) }
      return false
    }
    return true
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard
      let url = request.url,
      let originalURL = task.originalRequest?.url,
      isCurrent(session, for: originalURL),
      isCurrent(session, for: url)
    else {
      completionHandler(nil)
      return
    }
    completionHandler(request)
  }

  func urlSession(
    _ session: URLSession,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    authorizeSessionChallenge(session, challenge: challenge) { [weak self] authorized in
      guard let self, authorized else {
        completionHandler(.cancelAuthenticationChallenge, nil)
        return
      }
      self.performChallenge(session, challenge, task: nil, completion: completionHandler)
    }
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard
      let url = task.currentRequest?.url ?? task.originalRequest?.url,
      isCurrent(session, for: url),
      protectionSpace(challenge.protectionSpace, matches: url)
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    performChallenge(session, challenge, task: task, completion: completionHandler)
  }

  func handleChallenge(
    _ session: URLSession,
    _ challenge: URLAuthenticationChallenge,
    _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    task: URLSessionTask? = nil,
    requestContextValidated: Bool = false
  ) {
    guard requestContextValidated else {
      if let task {
        guard
          let url = task.currentRequest?.url ?? task.originalRequest?.url,
          isCurrent(session, for: url),
          protectionSpace(challenge.protectionSpace, matches: url)
        else {
          completionHandler(.cancelAuthenticationChallenge, nil)
          return
        }
        performChallenge(session, challenge, task: task, completion: completionHandler)
      } else {
        authorizeSessionChallenge(session, challenge: challenge) { [weak self] authorized in
          guard let self, authorized else {
            completionHandler(.cancelAuthenticationChallenge, nil)
            return
          }
          self.performChallenge(session, challenge, task: nil, completion: completionHandler)
        }
      }
      return
    }
    guard
      URLSessionManager.allowsProtectionSpace(challenge.protectionSpace),
      task.map({ task in
        guard let url = task.currentRequest?.url ?? task.originalRequest?.url else { return false }
        return protectionSpace(challenge.protectionSpace, matches: url)
      }) ?? true
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    performChallenge(session, challenge, task: task, completion: completionHandler)
  }

  func handleChallenge(
    _ session: URLSession,
    _ challenge: URLAuthenticationChallenge,
    _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    task: URLSessionTask,
    authorization: NetworkOriginAuthorization
  ) {
    guard
      let url = task.currentRequest?.url ?? task.originalRequest?.url,
      URLSessionManager.allowsProtectionSpace(
        challenge.protectionSpace,
        under: authorization
      ),
      protectionSpace(challenge.protectionSpace, matches: url)
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
    guard
      URLSessionManager.performAuthorizedDelivery(
        url,
        under: authorization,
        delivery: {
          self.performChallenge(
            session,
            challenge,
            task: task,
            completion: completionHandler
          )
          return true
        }
      ) == true
    else {
      completionHandler(.cancelAuthenticationChallenge, nil)
      return
    }
  }

  private func performChallenge(
    _ session: URLSession,
    _ challenge: URLAuthenticationChallenge,
    task: URLSessionTask?,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodClientCertificate:
      handleClientCertificate(session, completion: completion)
    case NSURLAuthenticationMethodHTTPBasic:
      handleBasicAuth(session, task: task, completion: completion)
    default: completion(.performDefaultHandling, nil)
    }
  }

  private func authorizeSessionChallenge(
    _ session: URLSession,
    challenge: URLAuthenticationChallenge,
    completion: @escaping (Bool) -> Void
  ) {
    guard let binding = binding(for: session),
      URLSessionManager.allowsProtectionSpace(
        challenge.protectionSpace,
        under: binding
      )
    else {
      completion(false)
      return
    }
    session.getAllTasks { [weak self] tasks in
      guard let self else {
        completion(false)
        return
      }
      completion(
        tasks.contains { task in
          guard let url = task.currentRequest?.url ?? task.originalRequest?.url else {
            return false
          }
          return URLSessionManager.allows(url, under: binding)
            && self.protectionSpace(challenge.protectionSpace, matches: url)
        }
      )
    }
  }

  private func binding(for session: URLSession) -> NetworkOriginAuthorization? {
    bindingsLock.withLock { sessionBindings[ObjectIdentifier(session)] }
  }

  private func isCurrent(_ session: URLSession, for url: URL) -> Bool {
    guard let binding = binding(for: session) else { return false }
    return URLSessionManager.allows(url, under: binding)
  }

  private func protectionSpace(_ protectionSpace: URLProtectionSpace, matches url: URL) -> Bool {
    guard let origin = NetworkCanonicalOrigin(protectionSpace: protectionSpace) else {
      return false
    }
    return origin.matches(url)
  }

  func urlSession(_ session: URLSession, didBecomeInvalidWithError error: Error?) {
    let invalidated = bindingsLock.withLock {
      sessionBindings.removeValue(forKey: ObjectIdentifier(session))
      return invalidationWaiters.removeValue(forKey: ObjectIdentifier(session))
    }
    invalidated?.signal()
  }

  private func handleClientCertificate(
    _ session: URLSession,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    let query: [String: Any] = [
      kSecClass as String: kSecClassIdentity,
      kSecAttrLabel as String: CLIENT_CERT_LABEL,
      kSecReturnRef as String: true,
    ]

    var item: CFTypeRef?
    let status = SecItemCopyMatching(query as CFDictionary, &item)
    if status == errSecSuccess, let identity = item {
      let credential = URLCredential(
        identity: identity as! SecIdentity,
        certificates: nil,
        persistence: .forSession)
      if #available(iOS 15, *) {
        VideoProxyServer.shared.session = session
      }
      return completion(.useCredential, credential)
    }
    completion(.performDefaultHandling, nil)
  }

  private func handleBasicAuth(
    _ session: URLSession,
    task: URLSessionTask?,
    completion: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    guard let url = task?.originalRequest?.url,
      let user = url.user,
      let password = url.password
    else {
      return completion(.performDefaultHandling, nil)
    }
    if #available(iOS 15, *) {
      VideoProxyServer.shared.session = session
    }
    let credential = URLCredential(user: user, password: password, persistence: .forSession)
    completion(.useCredential, credential)
  }
}
