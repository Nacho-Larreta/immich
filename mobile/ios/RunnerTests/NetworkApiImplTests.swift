import XCTest

@testable import Runner

private final class OwnershipProbe {}

final class NetworkApiImplTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    removeTestCookies()
    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
  }

  override func tearDownWithError() throws {
    removeTestCookies()
    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    try super.tearDownWithError()
  }

  func testReplaceRequestContextReplacesOnlyTheCanonicalOriginManagedCookies() throws {
    let unrelated = try cookie(name: "preference", value: "keep", domain: "unrelated.test")
    let staleAuth = try cookie(
      name: AuthCookie.accessToken.name, value: "stale", domain: "old.test")
    let parentDomainAuth = try cookie(
      name: AuthCookie.accessToken.name,
      value: "parent-stale",
      domain: ".photos.test",
      path: "/api"
    )
    URLSessionManager.cookieStorage.setCookie(unrelated)
    URLSessionManager.cookieStorage.setCookie(staleAuth)
    URLSessionManager.cookieStorage.setCookie(parentDomainAuth)

    try NetworkApiImpl().replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )

    let cookies = URLSessionManager.cookieStorage.cookies ?? []
    let authCookies = cookies.filter {
      AuthCookie.names.contains($0.name) && $0.domain == "photos.test"
    }
    XCTAssertEqual(Set(authCookies.map(\.domain)), ["photos.test"])
    XCTAssertEqual(
      authCookies.first { $0.name == AuthCookie.accessToken.name }?.value, "current-token")
    XCTAssertTrue(cookies.contains { $0.name == "preference" && $0.domain == "unrelated.test" })
    XCTAssertTrue(
      cookies.contains { $0.name == AuthCookie.accessToken.name && $0.domain == "old.test" })
    XCTAssertFalse(
      cookies.contains {
        $0.name == AuthCookie.accessToken.name && $0.domain == ".photos.test"
      }
    )
  }

  func testColdNativeInitializationBlocksPersistedAuthenticationUntilDartCommitsContext() throws {
    defer {
      RequestCaptureURLProtocol.onRequest = nil
      URLSessionManager.shared.recreateSession()
    }
    UserDefaults.group.set(["https://photos.test/api"], forKey: SERVER_URLS_KEY)
    UserDefaults.group.set(["X-Persisted": "must-not-escape"], forKey: HEADERS_KEY)
    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: AuthCookie.accessToken.name, value: "persisted-token", domain: "photos.test")
    )
    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: "preference", value: "keep", domain: "photos.test")
    )

    URLSessionManager.initializeBlockedRequestContext()

    let photosURL = try XCTUnwrap(URL(string: "https://photos.test/api/users/me"))
    XCTAssertFalse(URLSessionManager.allows(photosURL))
    XCTAssertTrue(authCookies().isEmpty)
    XCTAssertTrue(
      (URLSessionManager.cookieStorage.cookies ?? []).contains {
        $0.name == "preference" && $0.domain == "photos.test"
      }
    )
    let coldBackgroundConfiguration = URLSessionConfiguration.ephemeral
    URLSessionManager.configureRequestContext(on: coldBackgroundConfiguration)
    XCTAssertFalse(coldBackgroundConfiguration.httpShouldSetCookies)
    XCTAssertNil(coldBackgroundConfiguration.httpCookieStorage)
    XCTAssertNil(
      (coldBackgroundConfiguration.httpAdditionalHeaders as? [String: String])?["X-Persisted"]
    )

    let coldRequestHandled = expectation(description: "cold request intercepted")
    RequestCaptureURLProtocol.onRequest = { request in
      XCTAssertNil(request.value(forHTTPHeaderField: "X-Persisted"))
      let cookieHeader = request.value(forHTTPHeaderField: "Cookie") ?? ""
      XCTAssertFalse(AuthCookie.names.contains { cookieHeader.contains("\($0)=") })
      coldRequestHandled.fulfill()
    }
    URLSessionManager.shared.recreateSession(protocolClasses: [RequestCaptureURLProtocol.self])
    URLSessionManager.shared.session.dataTask(with: photosURL).resume()
    wait(for: [coldRequestHandled], timeout: 1)

    try URLSessionManager.replaceRequestContext(
      headers: ["X-Committed": "current"],
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )

    XCTAssertTrue(URLSessionManager.allows(photosURL))
    XCTAssertFalse(
      URLSessionManager.allows(try XCTUnwrap(URL(string: "https://photos.test:8443/api")))
    )
    let committedBackgroundConfiguration = URLSessionConfiguration.ephemeral
    URLSessionManager.configureRequestContext(on: committedBackgroundConfiguration)
    XCTAssertFalse(committedBackgroundConfiguration.httpShouldSetCookies)
    XCTAssertNil(committedBackgroundConfiguration.httpCookieStorage)
    XCTAssertNil(
      (committedBackgroundConfiguration.httpAdditionalHeaders as? [String: String])?["X-Committed"]
    )
    XCTAssertNil(
      (committedBackgroundConfiguration.httpAdditionalHeaders as? [String: String])?["Cookie"]
    )
  }

  func testApplicationLaunchEntrypointPurgesPersistedAuthenticationBeforePluginStartup() throws {
    UserDefaults.group.set(["https://photos.test/api"], forKey: SERVER_URLS_KEY)
    UserDefaults.group.set(["X-Persisted": "must-not-escape"], forKey: HEADERS_KEY)
    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: AuthCookie.accessToken.name, value: "persisted-token", domain: "photos.test")
    )

    let appDelegate = RequestContextObservingAppDelegate()
    _ = appDelegate.application(
      UIApplication.shared,
      didFinishLaunchingWithOptions: nil
    )

    XCTAssertTrue(appDelegate.observedBlockedRequestContext)
    XCTAssertFalse(
      URLSessionManager.allows(try XCTUnwrap(URL(string: "https://photos.test/api/users/me")))
    )
    XCTAssertTrue(authCookies().isEmpty)
    XCTAssertNil(UserDefaults.group.object(forKey: SERVER_URLS_KEY))
    XCTAssertNil(UserDefaults.group.object(forKey: HEADERS_KEY))
  }

  func testFlutterBootstrapIsSkippedOnlyForAnXCTestHost() {
    XCTAssertEqual(ProcessInfo.processInfo.environment["IMMICH_XCTEST_HOST"], "1")
    XCTAssertFalse(AppDelegate.shouldBootstrapFlutter(isXCTestHost: true))
    XCTAssertTrue(AppDelegate.shouldBootstrapFlutter(isXCTestHost: false))
  }

  func testConfigurationCreatedWhileBlockedNeverObservesLaterCommittedCookies() throws {
    URLSessionManager.initializeBlockedRequestContext()
    let configuration = URLSessionConfiguration.ephemeral

    URLSessionManager.configureRequestContext(
      on: configuration,
      keepCookieStorageBoundWhenBlocked: true
    )

    XCTAssertFalse(configuration.httpShouldSetCookies)
    XCTAssertNil(configuration.httpCookieStorage)

    try URLSessionManager.replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )

    XCTAssertNil(configuration.httpCookieStorage)
    XCTAssertNil(
      (configuration.httpAdditionalHeaders as? [String: String])?["Cookie"]
    )

    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    XCTAssertNil(configuration.httpCookieStorage)
  }

  func testReplaceRequestContextWithoutTokenClearsPreviousAuthentication() throws {
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://old.test", token: "stale"
    )

    try NetworkApiImpl().replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)

    XCTAssertFalse(
      (URLSessionManager.cookieStorage.cookies ?? []).contains {
        AuthCookie.names.contains($0.name) && $0.domain == "old.test"
      }
    )
  }

  func testPurgeRemovesApplicableAuthCookiesAndSendsNoAuthenticationCookieHeader() throws {
    defer {
      RequestCaptureURLProtocol.onRequest = nil
      URLSessionManager.shared.recreateSession()
    }
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://api.photos.test", token: "stale"
    )
    URLSessionManager.cookieStorage.setCookie(
      try cookie(
        name: AuthCookie.accessToken.name,
        value: "parent-stale",
        domain: ".photos.test",
        path: "/api"
      )
    )

    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: nil, token: nil
    )

    XCTAssertFalse(
      authCookies().contains {
        $0.domain == "api.photos.test" || $0.domain == ".photos.test"
      }
    )
    let requestHandled = expectation(description: "purged request intercepted")
    RequestCaptureURLProtocol.onRequest = { request in
      let cookieHeader = request.value(forHTTPHeaderField: "Cookie") ?? ""
      XCTAssertFalse(AuthCookie.names.contains { cookieHeader.contains("\($0)=") })
      requestHandled.fulfill()
    }
    URLSessionManager.shared.recreateSession(protocolClasses: [RequestCaptureURLProtocol.self])
    URLSessionManager.shared.session.dataTask(
      with: try XCTUnwrap(URL(string: "https://photos.test/api/users/me"))
    ).resume()

    wait(for: [requestHandled], timeout: 1)
  }

  func testStrictContextRejectsNonOriginValuesWithoutMutatingCurrentContext() throws {
    try URLSessionManager.replaceRequestContext(
      headers: ["X-Context": "current"],
      canonicalOrigin: "https://photos.test:8443",
      token: "current-token"
    )

    for invalidOrigin in [
      "https://photos.test/",
      "https://photos.test/api",
      "https://photos.test?mode=api",
      "https://photos.test#api",
      "https://user@photos.test",
      "ftp://photos.test",
    ] {
      XCTAssertThrowsError(
        try URLSessionManager.replaceRequestContext(
          headers: ["X-Context": "invalid"],
          canonicalOrigin: invalidOrigin,
          token: "invalid-token"
        )
      )
    }

    XCTAssertEqual(
      UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String],
      ["X-Context": "current"]
    )
    XCTAssertTrue(try XCTUnwrap(URL(string: "https://photos.test:8443/api")).isAllowed)
    XCTAssertFalse(try XCTUnwrap(URL(string: "https://photos.test/api")).isAllowed)
    XCTAssertEqual(authCookie(named: AuthCookie.accessToken.name)?.value, "current-token")
  }

  func testContextRejectsCredentialsWithoutOrigin() {
    XCTAssertThrowsError(
      try URLSessionManager.replaceRequestContext(
        headers: [:], canonicalOrigin: nil, token: "token")
    )
    XCTAssertThrowsError(
      try URLSessionManager.replaceRequestContext(
        headers: ["X-Context": "value"], canonicalOrigin: nil, token: nil)
    )
  }

  func testLegacyContextRejectsMultipleOriginsWithoutExposingCredentials() throws {
    XCTAssertThrowsError(
      try NetworkApiImpl().setRequestHeaders(
        headers: ["X-Context": "legacy"],
        serverUrls: ["https://photos.test/api", "http://aux.test:2283/api"],
        token: "legacy-token"
      )
    )

    XCTAssertFalse(try XCTUnwrap(URL(string: "https://photos.test/api")).isAllowed)
    XCTAssertFalse(try XCTUnwrap(URL(string: "http://aux.test:2283/api")).isAllowed)
    XCTAssertTrue(authCookies().isEmpty)
  }

  func testStrictCookieAndPolicyUseTheCanonicalPort() throws {
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://photos.test:8443", token: "token")

    XCTAssertTrue(try XCTUnwrap(URL(string: "https://photos.test:8443/api")).isAllowed)
    XCTAssertFalse(try XCTUnwrap(URL(string: "https://photos.test/api")).isAllowed)
    XCTAssertEqual(authCookie(named: AuthCookie.accessToken.name)?.portList, [8443])
  }

  func testRedirectDelegateRejectsDestinationOutsideActiveOrigin() throws {
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://photos.test", token: "token")
    let delegate = URLSessionManager.shared.delegate
    let task = URLSession.shared.dataTask(
      with: try XCTUnwrap(URL(string: "https://photos.test/api")))
    let response = try XCTUnwrap(
      HTTPURLResponse(
        url: try XCTUnwrap(URL(string: "https://photos.test/api")),
        statusCode: 302,
        httpVersion: nil,
        headerFields: nil
      )
    )

    var redirectedRequest: URLRequest?
    delegate.urlSession(
      URLSession.shared,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: try XCTUnwrap(URL(string: "https://evil.test/api")))
    ) { redirectedRequest = $0 }

    XCTAssertNil(redirectedRequest)
  }

  func testSameOriginReplacementCancelsOldSessionBeforeItCanSendStaleCredentials() throws {
    defer {
      RequestCaptureURLProtocol.onRequest = nil
      URLSessionManager.shared.recreateSession()
    }
    let staleURL = try XCTUnwrap(URL(string: "https://photos.test/api/users/stale"))
    let currentURL = try XCTUnwrap(URL(string: "https://photos.test/api/users/current"))
    try URLSessionManager.replaceRequestContext(
      headers: ["Authorization": "Bearer old-token", "X-Session": "old"],
      canonicalOrigin: "https://photos.test",
      token: "old-token"
    )
    URLSessionManager.shared.recreateSession(protocolClasses: [RequestCaptureURLProtocol.self])
    let staleSession = URLSessionManager.shared.session
    let staleTask = staleSession.dataTask(with: staleURL)
    let contextChangeCount = Mutex(0)
    let contextObserver = NotificationCenter.default.addObserver(
      forName: URLSessionManager.requestContextDidChange,
      object: nil,
      queue: nil
    ) { _ in contextChangeCount.withLock { $0 += 1 } }
    defer { NotificationCenter.default.removeObserver(contextObserver) }
    let staleRequest = expectation(description: "stale session must not send")
    staleRequest.isInverted = true
    RequestCaptureURLProtocol.onRequest = { _ in staleRequest.fulfill() }

    try URLSessionManager.replaceRequestContext(
      headers: ["Authorization": "Bearer new-token", "X-Session": "new"],
      canonicalOrigin: "https://photos.test",
      token: "new-token"
    )
    XCTAssertEqual(contextChangeCount.withLock { $0 }, 1)
    staleTask.resume()
    wait(for: [staleRequest], timeout: 0.2)

    let currentRequest = expectation(description: "current session request")
    RequestCaptureURLProtocol.onRequest = { request in
      XCTAssertEqual(request.url, currentURL)
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session"), "new")
      XCTAssertFalse((request.allHTTPHeaderFields ?? [:]).values.contains("Bearer old-token"))
      currentRequest.fulfill()
    }
    URLSessionManager.shared.recreateSession(protocolClasses: [RequestCaptureURLProtocol.self])
    let installedHeaders =
      URLSessionManager.shared.session.configuration.httpAdditionalHeaders
      as? [String: String]
    XCTAssertEqual(installedHeaders?["Authorization"], "Bearer new-token")
    XCTAssertEqual(installedHeaders?["X-Session"], "new")
    URLSessionManager.shared.session.dataTask(with: currentURL).resume()
    wait(for: [currentRequest], timeout: 1)
  }

  func testIdenticalRequestContextReplacementKeepsTheLiveSessionAndAuthorization() throws {
    let url = try XCTUnwrap(URL(string: "https://photos.test/api/assets"))
    let headers = ["Authorization": "Bearer current-token", "X-Session": "current"]
    try URLSessionManager.replaceRequestContext(
      headers: ["authorization": "Bearer current-token", "x-session": "current"],
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )
    let liveSession = URLSessionManager.shared.session
    let authorization = try XCTUnwrap(
      URLSessionManager.authorize(url, declaredOrigin: "https://photos.test")
    )
    let contextChangeCount = Mutex(0)
    let observer = NotificationCenter.default.addObserver(
      forName: URLSessionManager.requestContextDidChange,
      object: nil,
      queue: nil
    ) { _ in contextChangeCount.withLock { $0 += 1 } }
    defer { NotificationCenter.default.removeObserver(observer) }

    try URLSessionManager.replaceRequestContext(
      headers: headers,
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )

    XCTAssertTrue(URLSessionManager.shared.session === liveSession)
    XCTAssertEqual(contextChangeCount.withLock { $0 }, 0)
    XCTAssertTrue(URLSessionManager.allows(url, under: authorization))
  }

  func testRequestContextSnapshotTransfersOwnershipAcrossAnInterleavedTransition() throws {
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://photos.test", token: "old-token"
    )
    let liveSession = URLSessionManager.shared.session
    let snapshot = URLSessionManager.requestContextSnapshot()

    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://new.test", token: "new-token"
    )

    let transferredSession = Unmanaged<URLSession>
      .fromOpaque(snapshot.clientPointer)
      .takeRetainedValue()
    XCTAssertTrue(transferredSession === liveSession)
    XCTAssertFalse(URLSessionManager.shared.session === transferredSession)
  }

  func testRetainedPointerTransfersExactlyOneOwnershipReference() throws {
    weak var weakProbe: OwnershipProbe?
    var pointer: UnsafeMutableRawPointer?

    autoreleasepool {
      let probe = OwnershipProbe()
      weakProbe = probe
      pointer = URLSessionManager.retainedPointer(to: probe)
    }
    XCTAssertNotNil(weakProbe)

    let retainedPointer = try XCTUnwrap(pointer)
    autoreleasepool {
      _ = Unmanaged<OwnershipProbe>
        .fromOpaque(retainedPointer)
        .takeRetainedValue()
    }
    XCTAssertNil(weakProbe)
  }

  func testFailClosedTransitionDemotesAnAlreadyEmptyConfirmedContextExactlyOnce() throws {
    let confirmed = URLSessionManager.requestContextSnapshot()
    defer { Unmanaged<URLSession>.fromOpaque(confirmed.clientPointer).release() }
    XCTAssertTrue(confirmed.confirmed)

    try URLSessionManager.failClosedRequestContext()
    let blocked = URLSessionManager.requestContextSnapshot()
    defer { Unmanaged<URLSession>.fromOpaque(blocked.clientPointer).release() }
    XCTAssertFalse(blocked.confirmed)
    XCTAssertEqual(blocked.generation, confirmed.generation + 1)

    try URLSessionManager.failClosedRequestContext()
    let duplicate = URLSessionManager.requestContextSnapshot()
    defer { Unmanaged<URLSession>.fromOpaque(duplicate.clientPointer).release() }
    XCTAssertFalse(duplicate.confirmed)
    XCTAssertEqual(duplicate.generation, blocked.generation)
    XCTAssertEqual(duplicate.clientPointer, blocked.clientPointer)
  }

  func testInvalidationTimeoutCancelsObserversAndNeverPublishesReplacementContext() throws {
    try URLSessionManager.replaceRequestContext(
      headers: ["Authorization": "Bearer old-token"],
      canonicalOrigin: "https://photos.test",
      token: "old-token"
    )
    let staleSession = URLSessionManager.shared.session
    let contextChangeCount = Mutex(0)
    let contextObserver = NotificationCenter.default.addObserver(
      forName: URLSessionManager.requestContextDidChange,
      object: nil,
      queue: nil
    ) { _ in contextChangeCount.withLock { $0 += 1 } }
    URLSessionManager.overrideSessionInvalidationBarrierForTesting { false }
    defer {
      NotificationCenter.default.removeObserver(contextObserver)
      URLSessionManager.overrideSessionInvalidationBarrierForTesting(nil)
      URLSessionManager.initializeBlockedRequestContext()
    }

    XCTAssertThrowsError(
      try URLSessionManager.replaceRequestContext(
        headers: ["Authorization": "Bearer new-token"],
        canonicalOrigin: "https://photos.test",
        token: "new-token"
      )
    ) { error in
      guard case NetworkContextError.sessionInvalidationTimedOut = error else {
        return XCTFail("Expected sessionInvalidationTimedOut, got \(error)")
      }
    }

    XCTAssertEqual(contextChangeCount.withLock { $0 }, 1)
    XCTAssertFalse(URLSessionManager.shared.session === staleSession)
    XCTAssertFalse(URLSessionManager.allows(URL(string: "https://photos.test/api")!))
    XCTAssertNil(
      URLSessionManager.authorize(
        URL(string: "https://photos.test/api")!,
        declaredOrigin: "https://photos.test"
      )
    )
    let snapshot = URLSessionManager.requestContextSnapshot()
    defer { Unmanaged<URLSession>.fromOpaque(snapshot.clientPointer).release() }
    XCTAssertNil(snapshot.canonicalOrigin)
    XCTAssertFalse(snapshot.confirmed)
  }

  func testSameOriginRedirectFromReplacedSessionIsRejected() throws {
    let url = try XCTUnwrap(URL(string: "https://photos.test/api/assets"))
    try URLSessionManager.replaceRequestContext(
      headers: ["Authorization": "Bearer old-token"],
      canonicalOrigin: "https://photos.test",
      token: "old-token"
    )
    let staleSession = URLSessionManager.shared.session
    let staleTask = staleSession.dataTask(with: url)

    try URLSessionManager.replaceRequestContext(
      headers: ["Authorization": "Bearer new-token"],
      canonicalOrigin: "https://photos.test",
      token: "new-token"
    )

    var redirectedRequest: URLRequest?
    URLSessionManager.shared.delegate.urlSession(
      staleSession,
      task: staleTask,
      willPerformHTTPRedirection: try XCTUnwrap(
        HTTPURLResponse(url: url, statusCode: 302, httpVersion: nil, headerFields: nil)
      ),
      newRequest: URLRequest(url: url)
    ) { redirectedRequest = $0 }

    XCTAssertNil(redirectedRequest)
  }

  func testSessionChallengeWithoutExactOriginTaskIsCancelled() throws {
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://photos.test", token: nil
    )
    let challenge = URLAuthenticationChallenge(
      protectionSpace: URLProtectionSpace(
        host: "evil.test",
        port: 443,
        protocol: "https",
        realm: nil,
        authenticationMethod: NSURLAuthenticationMethodClientCertificate
      ),
      proposedCredential: nil,
      previousFailureCount: 0,
      failureResponse: nil,
      error: nil,
      sender: ChallengeSenderStub()
    )
    let handled = expectation(description: "challenge handled")

    URLSessionManager.shared.delegate.urlSession(
      URLSessionManager.shared.session,
      didReceive: challenge
    ) { disposition, _ in
      XCTAssertEqual(disposition, .cancelAuthenticationChallenge)
      handled.fulfill()
    }

    wait(for: [handled], timeout: 1)
  }

  func testSessionChallengeForExactOriginCurrentTaskCanUseConfiguredHandler() throws {
    defer {
      RequestCaptureURLProtocol.holdsRequestsOpen = false
      RequestCaptureURLProtocol.onRequest = nil
      URLSessionManager.shared.recreateSession()
    }
    try URLSessionManager.replaceRequestContext(
      headers: [:], canonicalOrigin: "https://photos.test", token: nil
    )
    RequestCaptureURLProtocol.holdsRequestsOpen = true
    let requestStarted = expectation(description: "current task started")
    RequestCaptureURLProtocol.onRequest = { _ in requestStarted.fulfill() }
    URLSessionManager.shared.recreateSession(protocolClasses: [RequestCaptureURLProtocol.self])
    let session = URLSessionManager.shared.session
    let task = session.dataTask(
      with: try XCTUnwrap(URL(string: "https://photos.test/api/assets"))
    )
    task.resume()
    wait(for: [requestStarted], timeout: 1)
    let challenge = URLAuthenticationChallenge(
      protectionSpace: URLProtectionSpace(
        host: "photos.test",
        port: 443,
        protocol: "https",
        realm: nil,
        authenticationMethod: NSURLAuthenticationMethodClientCertificate
      ),
      proposedCredential: nil,
      previousFailureCount: 0,
      failureResponse: nil,
      error: nil,
      sender: ChallengeSenderStub()
    )
    let handled = expectation(description: "challenge handled")

    URLSessionManager.shared.delegate.urlSession(session, didReceive: challenge) {
      disposition, _ in
      XCTAssertEqual(disposition, .performDefaultHandling)
      handled.fulfill()
    }

    wait(for: [handled], timeout: 1)
    task.cancel()
  }

  func testOriginalExportAuthorizationIsFailClosedAndRevalidated() throws {
    let photosURL = try XCTUnwrap(URL(string: "https://photos.test/api/assets/1/original"))
    let evilURL = try XCTUnwrap(URL(string: "https://evil.test/api/assets/1/original"))

    XCTAssertNil(
      URLSessionManager.authorize(photosURL, declaredOrigin: "https://photos.test")
    )

    try URLSessionManager.replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.test",
      token: nil
    )
    let authorization = try XCTUnwrap(
      URLSessionManager.authorize(photosURL, declaredOrigin: "https://photos.test")
    )
    XCTAssertTrue(URLSessionManager.allows(photosURL, under: authorization))
    XCTAssertFalse(URLSessionManager.allows(evilURL, under: authorization))
    XCTAssertNil(
      URLSessionManager.authorize(evilURL, declaredOrigin: "https://evil.test")
    )

    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    XCTAssertFalse(URLSessionManager.allows(photosURL, under: authorization))
  }

  func testAuthorizationIsInvalidatedWhenTheSameOriginContextIsReplaced() throws {
    let photosURL = try XCTUnwrap(URL(string: "https://photos.test/api/assets/1/original"))
    try URLSessionManager.replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.test",
      token: "old-token"
    )
    let staleAuthorization = try XCTUnwrap(
      URLSessionManager.authorize(photosURL, declaredOrigin: "https://photos.test")
    )

    try URLSessionManager.replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.test",
      token: "new-token"
    )

    XCTAssertFalse(URLSessionManager.allows(photosURL, under: staleAuthorization))
    XCTAssertNil(URLSessionManager.headers(under: staleAuthorization))
  }

  func testConcurrentContextReplacementPublishesOneCompleteContext() throws {
    let contexts = [
      (origin: "https://photos.test", header: "photos", token: "photos-token"),
      (origin: "https://aux.test:8443", header: "aux", token: "aux-token"),
    ]

    DispatchQueue.concurrentPerform(iterations: 40) { index in
      let context = contexts[index % contexts.count]
      try! URLSessionManager.replaceRequestContext(
        headers: ["X-Context": context.header],
        canonicalOrigin: context.origin,
        token: context.token
      )
    }

    let photosActive = try XCTUnwrap(URL(string: "https://photos.test/api")).isAllowed
    let auxActive = try XCTUnwrap(URL(string: "https://aux.test:8443/api")).isAllowed
    XCTAssertNotEqual(photosActive, auxActive)
    let expected = photosActive ? contexts[0] : contexts[1]
    XCTAssertEqual(
      UserDefaults.group.dictionary(forKey: HEADERS_KEY) as? [String: String],
      ["X-Context": expected.header]
    )
    XCTAssertEqual(authCookie(named: AuthCookie.accessToken.name)?.value, expected.token)
    XCTAssertEqual(
      authCookie(named: AuthCookie.accessToken.name)?.domain, URL(string: expected.origin)?.host)
  }

  func testCookieNotificationCanonicalizesAuthCookiesWithoutPurgingUnrelatedCookies() throws {
    defer {
      RequestCaptureURLProtocol.onRequest = nil
      URLSessionManager.shared.recreateSession()
    }

    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: "preference", value: "keep", domain: "unrelated.test")
    )
    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: "theme", value: "dark", domain: "photos.test", path: "/albums")
    )
    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: AuthCookie.accessToken.name, value: "other-origin", domain: "old.test")
    )

    try URLSessionManager.replaceRequestContext(
      headers: ["X-Immich-Context": "ios-test"],
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )
    let accessToken = try XCTUnwrap(authCookie(named: AuthCookie.accessToken.name))
    URLSessionManager.cookieStorage.deleteCookie(accessToken)
    URLSessionManager.cookieStorage.setCookie(
      try cookie(
        name: AuthCookie.accessToken.name,
        value: "stale-token",
        domain: "photos.test",
        port: 443,
        secure: false,
        httpOnly: false
      )
    )
    URLSessionManager.cookieStorage.setCookie(
      try cookie(
        name: AuthCookie.accessToken.name,
        value: "parent-token",
        domain: ".photos.test",
        path: "/api",
        secure: true,
        httpOnly: true
      )
    )

    NotificationCenter.default.post(
      name: NSNotification.Name.NSHTTPCookieManagerCookiesChanged,
      object: URLSessionManager.cookieStorage
    )

    let reconciliationQuiescent = expectation(
      description: "authentication cookie reconciliation quiescent"
    )
    URLSessionManager.notifyWhenCookieReconciliationIsQuiescent { report in
      XCTAssertGreaterThan(report.iterations, 0)
      XCTAssertLessThanOrEqual(report.iterations, 8)
      reconciliationQuiescent.fulfill()
    }
    wait(for: [reconciliationQuiescent], timeout: 1)

    let requestHandled = expectation(description: "authorized request intercepted")
    let expectedAuthPairs = [
      "immich_access_token=current-token",
      "immich_is_authenticated=true",
      "immich_auth_type=password",
    ]
    RequestCaptureURLProtocol.onRequest = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Immich-Context"), "ios-test")
      XCTAssertEqual(
        self.authPairs(in: request.value(forHTTPHeaderField: "Cookie")),
        expectedAuthPairs
      )
      requestHandled.fulfill()
    }
    URLSessionManager.shared.recreateSession(protocolClasses: [RequestCaptureURLProtocol.self])

    let requestURL = try XCTUnwrap(URL(string: "https://photos.test/api/users/me"))
    let request = URLRequest(url: requestURL)
    let task = URLSessionManager.shared.session.dataTask(with: request)
    task.resume()
    wait(for: [requestHandled], timeout: 1)
    task.cancel()

    let applicableAuthCookies = authCookies().filter {
      normalizedDomain($0.domain) == "photos.test"
    }
    XCTAssertEqual(applicableAuthCookies.count, AuthCookie.allCases.count)
    XCTAssertEqual(Set(applicableAuthCookies.map(\.name)), AuthCookie.names)
    XCTAssertTrue(
      applicableAuthCookies.allSatisfy { $0.domain == "photos.test" && $0.path == "/" }
    )
    let repairedAccessToken = try XCTUnwrap(
      applicableAuthCookies.first { $0.name == AuthCookie.accessToken.name }
    )
    XCTAssertEqual(repairedAccessToken.value, "current-token")
    XCTAssertEqual(repairedAccessToken.portList, [443])
    XCTAssertTrue(repairedAccessToken.isSecure)
    XCTAssertTrue(repairedAccessToken.isHTTPOnly)
    XCTAssertFalse(authCookies().contains { $0.domain == ".photos.test" || $0.path == "/api" })
    XCTAssertTrue(
      authCookies().contains {
        $0.name == AuthCookie.accessToken.name
          && $0.domain == "old.test"
          && $0.value == "other-origin"
      }
    )
    XCTAssertTrue(
      (URLSessionManager.cookieStorage.cookies ?? []).contains {
        $0.name == "preference" && $0.domain == "unrelated.test"
      }
    )
    XCTAssertTrue(
      (URLSessionManager.cookieStorage.cookies ?? []).contains {
        $0.name == "theme" && $0.domain == "photos.test" && $0.path == "/albums"
      }
    )
    let cookiesForRequest = URLSessionManager.cookieStorage.cookies(for: requestURL) ?? []
    let exporterCookies = cookiesForRequest.filter {
      normalizedDomain($0.domain) == requestURL.host
    }
    let exporterCookieHeader = HTTPCookie.requestHeaderFields(with: exporterCookies)["Cookie"]
    XCTAssertEqual(authPairs(in: exporterCookieHeader).sorted(), expectedAuthPairs.sorted())
  }

  private func cookie(
    name: String,
    value: String,
    domain: String,
    path: String = "/",
    port: Int? = nil,
    secure: Bool = false,
    httpOnly: Bool = false
  ) throws -> HTTPCookie {
    var properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: path,
      .expires: Date().addingTimeInterval(60),
    ]
    if let port { properties[.port] = String(port) }
    if secure { properties[.secure] = "TRUE" }
    if httpOnly { properties[.init("HttpOnly")] = "TRUE" }
    return try XCTUnwrap(HTTPCookie(properties: properties))
  }

  private func removeTestCookies() {
    for cookie in URLSessionManager.cookieStorage.cookies ?? []
    where ["old.test", "photos.test", "aux.test", "unrelated.test"].contains(
      cookie.domain.hasPrefix(".") ? String(cookie.domain.dropFirst()) : cookie.domain
    ) {
      URLSessionManager.cookieStorage.deleteCookie(cookie)
    }
  }

  private func authCookies() -> [HTTPCookie] {
    (URLSessionManager.cookieStorage.cookies ?? []).filter { AuthCookie.names.contains($0.name) }
  }

  private func authCookie(named name: String) -> HTTPCookie? {
    authCookies().first { $0.name == name }
  }

  private func normalizedDomain(_ domain: String) -> String {
    domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
  }

  private func authPairs(in cookieHeader: String?) -> [String] {
    cookieHeader?.split(separator: ";").map {
      $0.trimmingCharacters(in: .whitespaces)
    }.filter { pair in
      AuthCookie.names.contains(String(pair.split(separator: "=", maxSplits: 1)[0]))
    } ?? []
  }
}

private final class RequestContextObservingAppDelegate: AppDelegate {
  private(set) var observedBlockedRequestContext = false

  override func finishLaunchingAfterRequestContextInitialization(
    _ application: UIApplication,
    launchOptions: [UIApplication.LaunchOptionsKey: Any]?
  ) -> Bool {
    observedBlockedRequestContext = !URLSessionManager.allows(
      URL(string: "https://photos.test/api/users/me")!
    )
    return true
  }
}

private final class RequestCaptureURLProtocol: URLProtocol {
  static var onRequest: ((URLRequest) -> Void)?
  static var holdsRequestsOpen = false

  override class func canInit(with request: URLRequest) -> Bool {
    request.url?.host == "photos.test"
  }

  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

  override func startLoading() {
    Self.onRequest?(request)
    guard !Self.holdsRequestsOpen else { return }
    let response = HTTPURLResponse(
      url: request.url!, statusCode: 200, httpVersion: nil, headerFields: nil)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    client?.urlProtocol(self, didLoad: Data())
    client?.urlProtocolDidFinishLoading(self)
  }

  override func stopLoading() {}
}

private final class ChallengeSenderStub: NSObject, URLAuthenticationChallengeSender {
  func use(_ credential: URLCredential, for challenge: URLAuthenticationChallenge) {}

  func continueWithoutCredential(for challenge: URLAuthenticationChallenge) {}

  func cancel(_ challenge: URLAuthenticationChallenge) {}

  func performDefaultHandling(for challenge: URLAuthenticationChallenge) {}

  func rejectProtectionSpaceAndContinue(with challenge: URLAuthenticationChallenge) {}
}

extension URL {
  fileprivate var isAllowed: Bool { URLSessionManager.allows(self) }
}
