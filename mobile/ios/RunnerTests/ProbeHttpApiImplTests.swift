import Foundation
import XCTest

@testable import Runner

final class ProbeHttpApiImplTests: XCTestCase {
  private let forbiddenHeaders = [
    "Connection",
    "Cookie",
    "Host",
    "Keep-Alive",
    "Proxy-Authorization",
    "Proxy-Connection",
    "TE",
    "Trailer",
    "Transfer-Encoding",
    "Upgrade",
  ]
  private var context: URLSessionTestContext!
  private var api: ProbeHttpApiImpl!

  override func setUp() {
    super.setUp()
    context = URLSessionTestFactory.make()
    let configuration = context.session.configuration
    api = ProbeHttpApiImpl(configurationFactory: { configuration })
    try! api.openSession(
      session: NativeProbeHttpSession(sessionId: 1, timeoutMilliseconds: 3_000)
    )
  }

  override func tearDown() {
    try? api.closeSession(sessionId: 1)
    context.reset()
    api = nil
    context = nil
    super.tearDown()
  }

  func testReturnsBoundedUtf8ResponseWithoutCacheOrCookies() {
    let completed = expectation(description: "probe completed")
    let cookie = HTTPCookie(
      properties: [
        .domain: "photos.example.test",
        .name: "secret",
        .path: "/",
        .secure: "TRUE",
        .value: "must-not-leak",
      ]
    )!
    context.cookieStorage.setCookie(cookie)
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertEqual(request.request?.cachePolicy, .reloadIgnoringLocalCacheData)
      for name in self.forbiddenHeaders {
        XCTAssertNil(request.request?.value(forHTTPHeaderField: name), name)
      }
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "Authorization"), "Bearer expected")
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "x-api-key"), "token")
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "x-proxy-key"), "proxy")
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data("{\"res\":\"pong\"}".utf8)))
      XCTAssertTrue(request.finish())
    }

    let forbidden = Dictionary(uniqueKeysWithValues: forbiddenHeaders.map { ($0, "must-not-leak") })
    api.get(
      request: request(
        headers: forbidden.merging([
          "Authorization": "Bearer expected",
          "x-api-key": "token",
          "x-proxy-key": "proxy",
        ]) { _, expected in expected }
      )
    ) { result in
      let probe = try? result.get()
      XCTAssertNil(probe?.error)
      XCTAssertEqual(probe?.response?.statusCode, 200)
      XCTAssertEqual(probe?.response?.body, "{\"res\":\"pong\"}")
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
  }

  func testRejectsOriginMismatchBeforeStartingTransport() {
    let completed = expectation(description: "probe rejected")
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("Origin mismatch must not reach URLSession")
    }

    api.get(
      request: request(
        url: "https://other.example.test/api/server/ping",
        origin: "https://photos.example.test"
      )
    ) { result in
      XCTAssertEqual(try? result.get().error, .invalidRequest)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
  }

  func testRejectsCrossOriginRedirect() {
    let completed = expectation(description: "redirect rejected")
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(
        request.respond(
          statusCode: 302,
          headers: ["Location": "https://attacker.example.test/api/server/ping"]
        )
      )
      XCTAssertTrue(request.finish())
    }

    api.get(request: request()) { result in
      XCTAssertEqual(try? result.get().error, .redirectRejected)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
  }

  func testFollowsSameOriginRedirectAndReportsTheChain() {
    let completed = expectation(description: "redirect followed")
    ControllableURLProtocol.setRequestHandler { request in
      for name in self.forbiddenHeaders {
        XCTAssertNil(request.request?.value(forHTTPHeaderField: name), name)
      }
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "Authorization"), "Bearer expected")
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "x-api-key"), "token")
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "x-proxy-key"), "proxy")
      if request.request?.url?.path == "/api/server/ping" {
        XCTAssertTrue(
          request.respond(
            statusCode: 302,
            headers: ["Location": "https://photos.example.test/immich/api/server/ping"]
          )
        )
      } else {
        XCTAssertTrue(request.respond(statusCode: 200))
        XCTAssertTrue(request.send(Data("{\"res\":\"pong\"}".utf8)))
      }
      XCTAssertTrue(request.finish())
    }

    api.get(
      request: request(
        headers: [
          "Authorization": "Bearer expected",
          "Cookie": "must-not-leak=true",
          "Host": "attacker.example.test",
          "Proxy-Authorization": "Basic must-not-leak",
          "x-api-key": "token",
          "x-proxy-key": "proxy",
        ]
      )
    ) { result in
      let response = try? result.get().response
      XCTAssertEqual(response?.effectiveUrl, "https://photos.example.test/immich/api/server/ping")
      XCTAssertEqual(
        response?.redirectChain,
        ["https://photos.example.test/immich/api/server/ping"]
      )
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 2)
  }

  func testRejectsSixthSameOriginRedirect() {
    let completed = expectation(description: "redirect limit enforced")
    ControllableURLProtocol.setRequestHandler { request in
      let current = Int(request.request?.url?.lastPathComponent ?? "0") ?? 0
      XCTAssertTrue(
        request.respond(
          statusCode: 302,
          headers: ["Location": "https://photos.example.test/redirect/\(current + 1)"]
        )
      )
      XCTAssertTrue(request.finish())
    }

    api.get(
      request: request(url: "https://photos.example.test/redirect/0")
    ) { result in
      XCTAssertEqual(try? result.get().error, .redirectRejected)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 6)
  }

  func testRejectsRedirectContainingUserInfo() {
    let completed = expectation(description: "userinfo redirect rejected")
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(
        request.respond(
          statusCode: 302,
          headers: ["Location": "https://user:password@photos.example.test/api/server/ping"]
        )
      )
      XCTAssertTrue(request.finish())
    }

    api.get(request: request()) { result in
      XCTAssertEqual(try? result.get().error, .redirectRejected)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
  }

  func testRejectsBodyLargerThanOneMebibyte() {
    let completed = expectation(description: "oversized body rejected")
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data(repeating: 0x61, count: 1024 * 1024 + 1)))
    }

    api.get(request: request()) { result in
      XCTAssertEqual(try? result.get().error, .bodyTooLarge)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
  }

  func testMapsTimeoutAndCompletesExactlyOnce() {
    let completed = expectation(description: "timeout mapped once")
    completed.expectedFulfillmentCount = 1
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.fail(URLError(.timedOut)))
    }

    api.get(request: request()) { result in
      XCTAssertEqual(try? result.get().error, .timeout)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
  }

  func testCancellationAndCloseAreIdempotent() {
    let started = expectation(description: "request started")
    let completed = expectation(description: "request cancelled")
    completed.expectedFulfillmentCount = 1
    ControllableURLProtocol.setRequestHandler { _ in started.fulfill() }

    api.get(request: request()) { result in
      XCTAssertEqual(try? result.get().error, .cancelled)
      completed.fulfill()
    }
    wait(for: [started], timeout: 1)

    try? api.cancelRequest(sessionId: 1, requestId: 10)
    try? api.cancelRequest(sessionId: 1, requestId: 10)
    try? api.closeSession(sessionId: 1)
    try? api.closeSession(sessionId: 1)

    wait(for: [completed], timeout: 1)
  }

  private func request(
    url: String = "https://photos.example.test/api/server/ping",
    origin: String = "https://photos.example.test",
    headers: [String: String] = [:]
  ) -> NativeProbeHttpRequest {
    NativeProbeHttpRequest(
      sessionId: 1,
      requestId: 10,
      url: url,
      canonicalOrigin: origin,
      headers: headers
    )
  }
}
