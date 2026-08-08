import XCTest

@testable import Runner

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

  func testReplaceRequestContextKeepsAuthCookiesOnlyForCanonicalOrigin() throws {
    let unrelated = try cookie(name: "preference", value: "keep", domain: "unrelated.test")
    let staleAuth = try cookie(
      name: AuthCookie.accessToken.name, value: "stale", domain: "old.test")
    URLSessionManager.cookieStorage.setCookie(unrelated)
    URLSessionManager.cookieStorage.setCookie(staleAuth)

    try NetworkApiImpl().replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.test",
      token: "current-token"
    )

    let cookies = URLSessionManager.cookieStorage.cookies ?? []
    let authCookies = cookies.filter { AuthCookie.names.contains($0.name) }
    XCTAssertEqual(Set(authCookies.map(\.domain)), ["photos.test"])
    XCTAssertEqual(
      authCookies.first { $0.name == AuthCookie.accessToken.name }?.value, "current-token")
    XCTAssertTrue(cookies.contains { $0.name == "preference" && $0.domain == "unrelated.test" })
  }

  func testReplaceRequestContextWithoutTokenClearsPreviousAuthentication() throws {
    URLSessionManager.cookieStorage.setCookie(
      try cookie(name: AuthCookie.accessToken.name, value: "stale", domain: "old.test")
    )

    try NetworkApiImpl().replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)

    XCTAssertFalse(
      (URLSessionManager.cookieStorage.cookies ?? []).contains {
        AuthCookie.names.contains($0.name)
      }
    )
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

  func testLegacyContextPreservesEveryValidatedOrigin() throws {
    try NetworkApiImpl().setRequestHeaders(
      headers: ["X-Context": "legacy"],
      serverUrls: ["https://photos.test/api", "http://aux.test:2283/api"],
      token: "legacy-token"
    )

    XCTAssertTrue(try XCTUnwrap(URL(string: "https://photos.test/api")).isAllowed)
    XCTAssertTrue(try XCTUnwrap(URL(string: "http://aux.test:2283/api")).isAllowed)
    XCTAssertFalse(try XCTUnwrap(URL(string: "https://aux.test:2283/api")).isAllowed)
    let authDomains = Set(authCookies().map(\.domain))
    XCTAssertEqual(authDomains, ["photos.test", "aux.test"])
    XCTAssertTrue(
      authCookies().allSatisfy {
        $0.value == "legacy-token" || $0.name != AuthCookie.accessToken.name
      })
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

  private func cookie(name: String, value: String, domain: String) throws -> HTTPCookie {
    let properties: [HTTPCookiePropertyKey: Any] = [
      .name: name,
      .value: value,
      .domain: domain,
      .path: "/",
      .expires: Date().addingTimeInterval(60),
    ]
    return try XCTUnwrap(HTTPCookie(properties: properties))
  }

  private func removeTestCookies() {
    for cookie in URLSessionManager.cookieStorage.cookies ?? []
    where ["old.test", "photos.test", "aux.test", "unrelated.test"].contains(cookie.domain) {
      URLSessionManager.cookieStorage.deleteCookie(cookie)
    }
  }

  private func authCookies() -> [HTTPCookie] {
    (URLSessionManager.cookieStorage.cookies ?? []).filter { AuthCookie.names.contains($0.name) }
  }

  private func authCookie(named name: String) -> HTTPCookie? {
    authCookies().first { $0.name == name }
  }
}

extension URL {
  fileprivate var isAllowed: Bool { URLSessionManager.allows(self) }
}
