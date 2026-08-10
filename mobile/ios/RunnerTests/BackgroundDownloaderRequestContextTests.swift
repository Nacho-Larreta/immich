import XCTest
import background_downloader

@testable import Runner

final class BackgroundDownloaderRequestContextTests: XCTestCase {
  override func setUpWithError() throws {
    try super.setUpWithError()
    BackgroundDownloaderRequestContextBridge.reset()
    BackgroundRequestURLProtocol.reset()
    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
  }

  override func tearDownWithError() throws {
    BackgroundRequestURLProtocol.reset()
    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    BackgroundDownloaderRequestContextBridge.reset()
    try super.tearDownWithError()
  }

  func testSessionCreatedWhileBlockedUsesContextCommittedLater() throws {
    URLSessionManager.initializeBlockedRequestContext()
    URLSessionManager.patchBackgroundDownloader()
    let session = makeSession()
    let url = try requestURL()

    XCTAssertNil(BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: url)))
    XCTAssertNil(session.configuration.httpCookieStorage)
    XCTAssertNil(session.configuration.httpAdditionalHeaders)

    try commitContext(token: "current-token", sessionHeader: "current-session")

    let requestReceived = expectation(description: "current request received")
    BackgroundRequestURLProtocol.onRequest = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer current-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session"), "current-session")
      XCTAssertTrue(
        request.value(forHTTPHeaderField: "Cookie")?.contains(
          "immich_access_token=current-token"
        ) == true
      )
      requestReceived.fulfill()
    }

    let prepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: url))
    )
    let task = session.dataTask(with: prepared.request)
    XCTAssertTrue(
      BackgroundDownloaderRequestContextBridge.resume(task, context: prepared.context)
    )
    wait(for: [requestReceived], timeout: 1)
  }

  func testPurgePreventsPreparedAuthenticatedTaskFromStarting() throws {
    try commitContext(token: "old-token", sessionHeader: "old-session")
    URLSessionManager.patchBackgroundDownloader()
    let session = makeSession()
    let prepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: try requestURL()))
    )
    let task = session.dataTask(with: prepared.request)
    let requestReceived = expectation(description: "stale request must not start")
    requestReceived.isInverted = true
    BackgroundRequestURLProtocol.onRequest = { _ in requestReceived.fulfill() }

    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)

    XCTAssertFalse(
      BackgroundDownloaderRequestContextBridge.resume(task, context: prepared.context)
    )
    wait(for: [requestReceived], timeout: 0.2)
  }

  func testInvalidationTimeoutCancelsRunningTaskAndBlocksFuturePreparation() throws {
    try commitContext(token: "old-token", sessionHeader: "old-session")
    URLSessionManager.patchBackgroundDownloader()
    let session = makeSession()
    let prepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: try requestURL()))
    )
    let requestStarted = expectation(description: "old request started")
    BackgroundRequestURLProtocol.holdsRequestsOpen = true
    BackgroundRequestURLProtocol.onRequest = { _ in requestStarted.fulfill() }
    let task = session.dataTask(with: prepared.request)
    XCTAssertTrue(
      BackgroundDownloaderRequestContextBridge.resume(task, context: prepared.context)
    )
    wait(for: [requestStarted], timeout: 1)

    URLSessionManager.overrideSessionInvalidationBarrierForTesting { false }
    defer { URLSessionManager.overrideSessionInvalidationBarrierForTesting(nil) }
    XCTAssertThrowsError(
      try commitContext(token: "new-token", sessionHeader: "new-session")
    ) { error in
      guard case NetworkContextError.sessionInvalidationTimedOut = error else {
        return XCTFail("Expected sessionInvalidationTimedOut, got \(error)")
      }
    }

    XCTAssertTrue(task.state == .canceling || task.state == .completed)
    XCTAssertFalse(BackgroundDownloaderRequestContextBridge.shouldProcessCallback(for: task))
    XCTAssertNil(
      BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: try requestURL()))
    )
  }

  func testSameSessionRejectsOldContextAndSendsOnlyReplacementCredentials() throws {
    try commitContext(token: "old-token", sessionHeader: "old-session")
    URLSessionManager.patchBackgroundDownloader()
    let session = makeSession()
    let url = try requestURL()
    var staleRequest = URLRequest(url: url)
    staleRequest.setValue("Bearer task-token", forHTTPHeaderField: "Authorization")
    staleRequest.setValue("task-cookie=stale", forHTTPHeaderField: "Cookie")
    staleRequest.setValue("task-session", forHTTPHeaderField: "X-Session")
    let oldPrepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(staleRequest)
    )
    let oldTask = session.dataTask(with: oldPrepared.request)

    try commitContext(token: "new-token", sessionHeader: "new-session")

    XCTAssertFalse(
      BackgroundDownloaderRequestContextBridge.resume(oldTask, context: oldPrepared.context)
    )
    let replacementReceived = expectation(description: "replacement request received")
    BackgroundRequestURLProtocol.onRequest = { request in
      let headers = request.allHTTPHeaderFields ?? [:]
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer new-token")
      XCTAssertEqual(request.value(forHTTPHeaderField: "X-Session"), "new-session")
      XCTAssertFalse(headers.values.contains { $0.contains("old-token") })
      XCTAssertFalse(headers.values.contains { $0.contains("task-token") })
      XCTAssertFalse(headers.values.contains { $0.contains("task-cookie") })
      replacementReceived.fulfill()
    }
    let newPrepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(staleRequest)
    )
    let newTask = session.dataTask(with: newPrepared.request)
    XCTAssertTrue(
      BackgroundDownloaderRequestContextBridge.resume(newTask, context: newPrepared.context)
    )
    wait(for: [replacementReceived], timeout: 1)
  }

  func testContextReplacementRejectsRedirectFromRunningOldRevision() throws {
    try commitContext(token: "old-token", sessionHeader: "old-session")
    URLSessionManager.patchBackgroundDownloader()
    let session = makeSession()
    let prepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: try requestURL()))
    )
    let requestStarted = expectation(description: "old request started")
    BackgroundRequestURLProtocol.holdsRequestsOpen = true
    BackgroundRequestURLProtocol.onRequest = { _ in requestStarted.fulfill() }
    let task = session.dataTask(with: prepared.request)
    XCTAssertTrue(
      BackgroundDownloaderRequestContextBridge.resume(task, context: prepared.context)
    )
    wait(for: [requestStarted], timeout: 1)

    try commitContext(token: "new-token", sessionHeader: "new-session")
    let redirect = URLRequest(url: try XCTUnwrap(URL(string: "https://photos.test/api/next")))

    XCTAssertNil(BackgroundDownloaderRequestContextBridge.securedRedirect(redirect, for: task))
  }

  func testHTTPRequestsRequireForegroundExecution() throws {
    let httpURL = try XCTUnwrap(URL(string: "http://photos.test/api/assets"))
    let httpsURL = try XCTUnwrap(URL(string: "https://photos.test/api/assets"))

    XCTAssertEqual(
      BackgroundDownloaderRequestContextBridge.executionMode(for: httpURL),
      .foreground
    )
    XCTAssertEqual(
      BackgroundDownloaderRequestContextBridge.executionMode(for: httpsURL),
      .background
    )
  }

  func testBlockedBridgeCancelsRestoredTaskWithoutBinding() throws {
    URLSessionManager.initializeBlockedRequestContext()
    URLSessionManager.patchBackgroundDownloader()
    let task = makeSession().dataTask(with: URLRequest(url: try requestURL()))

    let cancelled = BackgroundDownloaderRequestContextBridge.cancelRestoredTasks([task])

    XCTAssertEqual(cancelled, 1)
    XCTAssertEqual(task.state, .canceling)
    XCTAssertFalse(BackgroundDownloaderRequestContextBridge.shouldProcessCallback(for: task))
  }

  func testProcessResetMakesPreviouslyPreparedTaskUnboundAndCancelsItOnRestore() throws {
    try commitContext(token: "old-token", sessionHeader: "old-session")
    URLSessionManager.patchBackgroundDownloader()
    let prepared = try XCTUnwrap(
      BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: try requestURL()))
    )
    let task = makeSession().dataTask(with: prepared.request)
    let requestStarted = expectation(description: "bound request started")
    BackgroundRequestURLProtocol.holdsRequestsOpen = true
    BackgroundRequestURLProtocol.onRequest = { _ in requestStarted.fulfill() }
    XCTAssertTrue(
      BackgroundDownloaderRequestContextBridge.resume(task, context: prepared.context)
    )
    wait(for: [requestStarted], timeout: 1)

    BackgroundDownloaderRequestContextBridge.resetForProcessTerminationSimulation()
    URLSessionManager.initializeBlockedRequestContext()
    URLSessionManager.patchBackgroundDownloader()

    XCTAssertEqual(BackgroundDownloaderRequestContextBridge.cancelRestoredTasks([task]), 1)
    XCTAssertEqual(task.state, .canceling)
  }

  private func makeSession() -> URLSession {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [BackgroundRequestURLProtocol.self]
    BackgroundDownloaderRequestContextBridge.secureConfiguration(configuration)
    return URLSession(configuration: configuration)
  }

  private func commitContext(token: String, sessionHeader: String) throws {
    try URLSessionManager.replaceRequestContext(
      headers: [
        "Authorization": "Bearer \(token)",
        "X-Session": sessionHeader,
      ],
      canonicalOrigin: "https://photos.test",
      token: token
    )
  }

  private func requestURL() throws -> URL {
    try XCTUnwrap(URL(string: "https://photos.test/api/assets"))
  }
}

private final class BackgroundRequestURLProtocol: URLProtocol {
  static var holdsRequestsOpen = false
  static var onRequest: ((URLRequest) -> Void)?

  static func reset() {
    holdsRequestsOpen = false
    onRequest = nil
  }

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
