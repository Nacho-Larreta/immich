import Foundation
import native_video_player

let CLIENT_CERT_LABEL = "com.nacholarreta.nachofotos.client_identity"
let HEADERS_KEY = "immich.request_headers"
let SERVER_URLS_KEY = "immich.server_urls"
let APP_GROUP = "group.com.nacholarreta.nachofotos.share"
let COOKIE_EXPIRY_DAYS: TimeInterval = 400

enum AuthCookie: CaseIterable {
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

struct NetworkCanonicalOrigin: Equatable {
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
}

extension UserDefaults {
  static let group = UserDefaults(suiteName: APP_GROUP)!
}

/// Manages a shared URLSession with SSL configuration support.
/// Old sessions are kept alive by Dart's FFI retain until all isolates release them.
class URLSessionManager: NSObject {
  static let shared = URLSessionManager()

  private(set) var session: URLSession
  let delegate: URLSessionManagerDelegate
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
    let version = Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "unknown"
    return "immich-ios/\(version)"
  }()
  static let cookieStorage = HTTPCookieStorage.sharedCookieStorage(forGroupContainerIdentifier: APP_GROUP)
  private static var serverUrls: [String] = []
  private static var isSyncing = false
  private static var activeCanonicalOrigins: [NetworkCanonicalOrigin] = []
  private static let requestContextLock = NSRecursiveLock()

  var sessionPointer: UnsafeMutableRawPointer {
    Unmanaged.passUnretained(session).toOpaque()
  }

  private override init() {
    delegate = URLSessionManagerDelegate()
    session = Self.buildSession(delegate: delegate)
    super.init()
    Self.serverUrls = UserDefaults.group.stringArray(forKey: SERVER_URLS_KEY) ?? []
    Self.activeCanonicalOrigins = Self.serverUrls.compactMap(NetworkCanonicalOrigin.init(endpoint:))
    NotificationCenter.default.addObserver(
      Self.self,
      selector: #selector(Self.cookiesDidChange),
      name: NSNotification.Name.NSHTTPCookieManagerCookiesChanged,
      object: Self.cookieStorage
    )
  }

  func recreateSession() {
    session = Self.buildSession(delegate: delegate)
  }

  static func clearAuthCookies() {
    withRequestContextLock {
      clearAuthCookiesLocked()
    }
  }

  static func replaceRequestContext(headers: [String: String], canonicalOrigin: String?, token: String?) throws {
    let origin = try validateContext(headers: headers, canonicalOrigin: canonicalOrigin, token: token)
    withRequestContextLock {
      replaceRequestContextLocked(headers: headers, origins: origin.map { [$0] } ?? [], token: token)
    }
  }

  static func replaceLegacyRequestContext(headers: [String: String], serverUrls: [String], token: String?) throws {
    let origins = serverUrls.compactMap(NetworkCanonicalOrigin.init(endpoint:))
    guard origins.count == serverUrls.count else {
      throw NetworkContextError.invalidCanonicalOrigin
    }
    if token != nil && origins.isEmpty { throw NetworkContextError.tokenWithoutOrigin }
    if origins.isEmpty && !headers.isEmpty { throw NetworkContextError.headersWithoutOrigin }
    withRequestContextLock {
      replaceRequestContextLocked(headers: headers, origins: origins, token: token)
    }
  }

  static func allows(_ url: URL) -> Bool {
    withRequestContextLock {
      !activeCanonicalOrigins.isEmpty && activeCanonicalOrigins.contains { $0.matches(url) }
    }
  }

  static func authorize(
    _ url: URL,
    declaredOrigin: String
  ) -> NetworkOriginAuthorization? {
    guard let declared = NetworkCanonicalOrigin(origin: declaredOrigin) else { return nil }
    return withRequestContextLock {
      guard
        activeCanonicalOrigins.contains(declared),
        declared.matches(url)
      else { return nil }
      return NetworkOriginAuthorization(
        scheme: declared.scheme,
        host: declared.host,
        port: declared.port
      )
    }
  }

  static func allows(
    _ url: URL,
    under authorization: NetworkOriginAuthorization
  ) -> Bool {
    let authorizedOrigin = NetworkCanonicalOrigin(
      authorization: authorization
    )
    return withRequestContextLock {
      activeCanonicalOrigins.contains(authorizedOrigin) && authorizedOrigin.matches(url)
    }
  }

  static func headers(
    under authorization: NetworkOriginAuthorization
  ) -> [String: String]? {
    let authorizedOrigin = NetworkCanonicalOrigin(authorization: authorization)
    return withRequestContextLock {
      guard activeCanonicalOrigins.contains(authorizedOrigin) else { return nil }
      var headers =
        UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String]
        ?? [:]
      headers["User-Agent"] = headers["User-Agent"] ?? userAgent
      return headers
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
    token: String?
  ) {
    clearAuthCookiesLocked()
    activeCanonicalOrigins = origins
    serverUrls = origins.map(\.string)
    UserDefaults.group.set(serverUrls, forKey: SERVER_URLS_KEY)
    installAuthCookiesLocked(token: token, origins: origins)
    installHeadersLocked(headers)
  }

  private static func clearAuthCookiesLocked() {
    isSyncing = true
    defer { isSyncing = false }
    for cookie in cookieStorage.cookies ?? [] where AuthCookie.names.contains(cookie.name) {
      cookieStorage.deleteCookie(cookie)
    }
  }

  private static func installAuthCookiesLocked(token: String?, origins: [NetworkCanonicalOrigin]) {
    guard let token else { return }
    let expiry = Date().addingTimeInterval(COOKIE_EXPIRY_DAYS * 24 * 60 * 60)
    let values: [AuthCookie: String] = [
      .accessToken: token,
      .isAuthenticated: "true",
      .authType: "password",
    ]
    for origin in origins {
      for (cookie, value) in values {
        var properties: [HTTPCookiePropertyKey: Any] = [
          .name: cookie.name,
          .value: value,
          .domain: origin.host,
          .path: "/",
          .port: String(origin.port),
          .expires: expiry,
        ]
        if origin.scheme == "https" { properties[.secure] = "TRUE" }
        if cookie.httpOnly { properties[.init("HttpOnly")] = "TRUE" }
        if let httpCookie = HTTPCookie(properties: properties) {
          cookieStorage.setCookie(httpCookie)
        }
      }
    }
  }

  private static func installHeadersLocked(_ headers: [String: String]) {
    guard headers != UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String] else { return }
    UserDefaults.group.set(headers, forKey: HEADERS_KEY)
    shared.recreateSession()
  }

  private static func withRequestContextLock<T>(_ body: () throws -> T) rethrows -> T {
    requestContextLock.lock()
    defer { requestContextLock.unlock() }
    return try body()
  }

  @objc private static func cookiesDidChange(_ notification: Notification) {
    withRequestContextLock {
      guard !isSyncing, !serverUrls.isEmpty else { return }
      syncAuthCookies()
    }
  }

  private static func syncAuthCookies() {
    let serverHosts = Set(activeCanonicalOrigins.map(\.host))
    let allCookies = cookieStorage.cookies ?? []
    let now = Date()

    let serverAuthCookies = allCookies.filter {
      AuthCookie.names.contains($0.name) && serverHosts.contains($0.domain)
    }

    var sourceCookies: [String: HTTPCookie] = [:]
    for cookie in serverAuthCookies {
      if cookie.expiresDate.map({ $0 > now }) ?? true {
        sourceCookies[cookie.name] = cookie
      }
    }

    isSyncing = true
    defer { isSyncing = false }

    for cookie in allCookies where AuthCookie.names.contains(cookie.name) {
      cookieStorage.deleteCookie(cookie)
    }
    if sourceCookies.isEmpty { return }

    for origin in activeCanonicalOrigins {
      for (_, source) in sourceCookies {
        var properties: [HTTPCookiePropertyKey: Any] = [
          .name: source.name,
          .value: source.value,
          .domain: origin.host,
          .path: "/",
          .port: String(origin.port),
          .expires: source.expiresDate ?? Date().addingTimeInterval(COOKIE_EXPIRY_DAYS * 24 * 60 * 60),
        ]
        if origin.scheme == "https" { properties[.secure] = "TRUE" }
        if source.isHTTPOnly { properties[.init("HttpOnly")] = "TRUE" }

        if let cookie = HTTPCookie(properties: properties) {
          cookieStorage.setCookie(cookie)
        }
      }
    }
  }

  private static func buildSession(delegate: URLSessionManagerDelegate) -> URLSession {
    let config = URLSessionConfiguration.default
    config.urlCache = urlCache
    config.httpCookieStorage = cookieStorage
    config.httpMaximumConnectionsPerHost = 64
    config.timeoutIntervalForRequest = 60

    var headers = UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String] ?? [:]
    headers["User-Agent"] = headers["User-Agent"] ?? userAgent
    config.httpAdditionalHeaders = headers

    return URLSession(configuration: config, delegate: delegate, delegateQueue: nil)
  }

  /// Patches background_downloader's URLSession to use shared auth configuration.
  /// Must be called before background_downloader creates its session (i.e. early in app startup).
  static func patchBackgroundDownloader() {
    // Swizzle URLSessionConfiguration.background(withIdentifier:) to inject shared config
    let originalSel = NSSelectorFromString("backgroundSessionConfigurationWithIdentifier:")
    let swizzledSel = #selector(URLSessionConfiguration.immich_background(withIdentifier:))
    if let original = class_getClassMethod(URLSessionConfiguration.self, originalSel),
       let swizzled = class_getClassMethod(URLSessionConfiguration.self, swizzledSel) {
      method_exchangeImplementations(original, swizzled)
    }

    // Add auth challenge handling to background_downloader's UrlSessionDelegate
    guard let targetClass = NSClassFromString("background_downloader.UrlSessionDelegate") else { return }

    let sessionBlock: @convention(block) (AnyObject, URLSession, URLAuthenticationChallenge,
        @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void
    = { _, session, challenge, completion in
      URLSessionManager.shared.delegate.handleChallenge(session, challenge, completion)
    }
    class_replaceMethod(targetClass,
      NSSelectorFromString("URLSession:didReceiveChallenge:completionHandler:"),
      imp_implementationWithBlock(sessionBlock), "v@:@@@?")

    let taskBlock: @convention(block) (AnyObject, URLSession, URLSessionTask, URLAuthenticationChallenge,
        @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void) -> Void
    = { _, session, task, challenge, completion in
      URLSessionManager.shared.delegate.handleChallenge(session, challenge, completion, task: task)
    }
    class_replaceMethod(targetClass,
      NSSelectorFromString("URLSession:task:didReceiveChallenge:completionHandler:"),
      imp_implementationWithBlock(taskBlock), "v@:@@@@?")
  }
}

enum NetworkContextError: Error {
  case invalidCanonicalOrigin
  case tokenWithoutOrigin
  case headersWithoutOrigin
}

private extension URLSessionConfiguration {
  @objc dynamic class func immich_background(withIdentifier id: String) -> URLSessionConfiguration {
    // After swizzle, this calls the original implementation
    let config = immich_background(withIdentifier: id)
    config.httpCookieStorage = URLSessionManager.cookieStorage
    config.httpAdditionalHeaders = ["User-Agent": URLSessionManager.userAgent]
    return config
  }
}

class URLSessionManagerDelegate: NSObject, URLSessionTaskDelegate, URLSessionWebSocketDelegate {
  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    willPerformHTTPRedirection response: HTTPURLResponse,
    newRequest request: URLRequest,
    completionHandler: @escaping (URLRequest?) -> Void
  ) {
    guard let url = request.url, URLSessionManager.allows(url) else {
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
    handleChallenge(session, challenge, completionHandler)
  }

  func urlSession(
    _ session: URLSession,
    task: URLSessionTask,
    didReceive challenge: URLAuthenticationChallenge,
    completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void
  ) {
    handleChallenge(session, challenge, completionHandler, task: task)
  }

  func handleChallenge(
    _ session: URLSession,
    _ challenge: URLAuthenticationChallenge,
    _ completionHandler: @escaping (URLSession.AuthChallengeDisposition, URLCredential?) -> Void,
    task: URLSessionTask? = nil
  ) {
    switch challenge.protectionSpace.authenticationMethod {
    case NSURLAuthenticationMethodClientCertificate: handleClientCertificate(session, completion: completionHandler)
    case NSURLAuthenticationMethodHTTPBasic: handleBasicAuth(session, task: task, completion: completionHandler)
    default: completionHandler(.performDefaultHandling, nil)
    }
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
      let credential = URLCredential(identity: identity as! SecIdentity,
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
