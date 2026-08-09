import Foundation
import XCTest

@testable import Runner

private enum RemoteImageTestError: Error {
  case missingCompletion
}

final class RemoteImagesImplTests: XCTestCase {
  private var context: URLSessionTestContext!
  private var performance: RecordingPerformanceRecorder!
  private var api: RemoteImageApiImpl!

  override func setUp() {
    super.setUp()
    context = URLSessionTestFactory.make()
    performance = RecordingPerformanceRecorder()
    api = RemoteImageApiImpl(
      sessionConfiguration: context.session.configuration,
      performanceRecorder: performance
    )
  }

  override func tearDown() {
    api.dispose()
    context.reset()
    api = nil
    performance = nil
    context = nil
    super.tearDown()
  }

  func testCacheOnlyReturnsCachedPayloadWithoutStartingNetwork() {
    let url = URL(string: "https://photos.example.test/api/assets/cached/thumbnail")!
    let data = Data("cached-image".utf8)
    let response = HTTPURLResponse(url: url, statusCode: 200, httpVersion: nil, headerFields: nil)!
    context.cache.storeCachedResponse(
      CachedURLResponse(response: response, data: data, storagePolicy: .allowedInMemoryOnly),
      for: URLRequest(url: url)
    )
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("cacheOnly must not start a network request on a cache hit")
    }

    let result = request(
      url: url,
      origin: "https://photos.example.test",
      policy: .cacheOnly,
      requestId: 2
    )

    assertEncodedPayload(result, equals: data)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 1)
  }

  func testCacheOnlyReturnsCacheMissWithoutStartingNetwork() {
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("cacheOnly must not start a network request on a cache miss")
    }

    let result = request(
      url: URL(string: "https://photos.example.test/api/assets/missing/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheOnly,
      requestId: 2
    )

    XCTAssertEqual(try? result.get().error, .cacheMiss)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 1)
  }

  func testCacheOnlyDoesNotReuseAnEntryFromAnotherOrigin() {
    let otherOriginURL = URL(string: "https://other.example.test/api/assets/shared/thumbnail")!
    let otherOriginData = Data("other-origin".utf8)
    let otherOriginResponse = HTTPURLResponse(
      url: otherOriginURL,
      statusCode: 200,
      httpVersion: nil,
      headerFields: nil
    )!
    context.cache.storeCachedResponse(
      CachedURLResponse(
        response: otherOriginResponse,
        data: otherOriginData,
        storagePolicy: .allowedInMemoryOnly
      ),
      for: URLRequest(url: otherOriginURL)
    )
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("cacheOnly must not start a network request")
    }

    let result = request(
      url: URL(string: "https://photos.example.test/api/assets/shared/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheOnly,
      requestId: 8
    )

    XCTAssertEqual(try? result.get().error, .cacheMiss)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
  }

  func testCacheThenNetworkPreservesNetworkFallback() {
    let data = Data("network-image".utf8)
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertEqual(request.request?.cachePolicy, .returnCacheDataElseLoad)
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(data))
      XCTAssertTrue(request.finish())
    }

    let result = request(
      url: URL(string: "https://photos.example.test/api/assets/network/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheThenNetwork,
      requestId: 3
    )

    assertEncodedPayload(result, equals: data)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
  }

  func testRequestDoesNotReceiveCookiesBelongingToAnotherHost() {
    let otherHostCookie = HTTPCookie(
      properties: [
        .domain: "other.example.test",
        .name: "cross_host_secret",
        .path: "/",
        .secure: "TRUE",
        .value: "must-not-leak",
      ]
    )!
    let sameHostCookie = HTTPCookie(
      properties: [
        .domain: "photos.example.test",
        .name: "same_host_auth",
        .path: "/",
        .secure: "TRUE",
        .value: "expected",
      ]
    )!
    context.cookieStorage.setCookie(otherHostCookie)
    context.cookieStorage.setCookie(sameHostCookie)
    ControllableURLProtocol.setRequestHandler { request in
      let cookieHeader = request.request?.value(forHTTPHeaderField: "Cookie") ?? ""
      XCTAssertTrue(cookieHeader.contains("same_host_auth=expected"))
      XCTAssertFalse(cookieHeader.contains("cross_host_secret"))
      XCTAssertFalse(cookieHeader.contains("must-not-leak"))
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data("image".utf8)))
      XCTAssertTrue(request.finish())
    }

    let result = request(
      url: URL(string: "https://photos.example.test/api/assets/1/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheThenNetwork,
      requestId: 8
    )

    assertEncodedPayload(result, equals: Data("image".utf8))
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
  }

  func testRejectsRequestWhoseURLDoesNotMatchCanonicalOrigin() {
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("An origin mismatch must be rejected before URLSession")
    }

    let result = request(
      url: URL(string: "https://other.example.test/api/assets/1/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheThenNetwork,
      requestId: 4
    )

    XCTAssertEqual(try? result.get().error, .wrongServer)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
  }

  func testRejectsOriginContainingPathUserInfoOrQuery() {
    let invalidOrigins = [
      "https://photos.example.test/api",
      "https://user@photos.example.test",
      "https://photos.example.test?tenant=other",
    ]
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("Invalid origin input must be rejected before URLSession")
    }

    for (index, origin) in invalidOrigins.enumerated() {
      let result = request(
        url: URL(string: "https://photos.example.test/api/assets/1/thumbnail")!,
        origin: origin,
        policy: .cacheThenNetwork,
        requestId: Int64(20 + index)
      )
      XCTAssertEqual(try? result.get().error, .wrongServer)
    }
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
  }

  func testRejectsSchemeAndPortMismatch() {
    let mismatchedOrigins = [
      "http://photos.example.test",
      "https://photos.example.test:8443",
    ]
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("Scheme or port mismatch must be rejected before URLSession")
    }

    for (index, origin) in mismatchedOrigins.enumerated() {
      let result = request(
        url: URL(string: "https://photos.example.test/api/assets/1/thumbnail")!,
        origin: origin,
        policy: .cacheThenNetwork,
        requestId: Int64(30 + index)
      )
      XCTAssertEqual(try? result.get().error, .wrongServer)
    }
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
  }

  func testRejectsCrossOriginRedirectWithoutLoadingRedirectTarget() {
    let sourceURL = URL(string: "https://photos.example.test/api/assets/1/thumbnail")!
    let redirectURL = URL(string: "https://other.example.test/api/assets/1/thumbnail")!
    let session = URLSession(configuration: .ephemeral)
    let task = session.dataTask(with: sourceURL)
    let delegate = RemoteImageSessionDelegate(challengeHandler: nil)
    delegate.register(
      task: task,
      origin: RemoteImageCanonicalOrigin(origin: "https://photos.example.test")!
    )
    let response = HTTPURLResponse(
      url: sourceURL,
      statusCode: 302,
      httpVersion: nil,
      headerFields: ["Location": redirectURL.absoluteString]
    )!
    var followedRequest: URLRequest?

    delegate.urlSession(
      session,
      task: task,
      willPerformHTTPRedirection: response,
      newRequest: URLRequest(url: redirectURL)
    ) { followedRequest = $0 }

    XCTAssertNil(followedRequest)
    XCTAssertTrue(delegate.consumeRejectedRedirect(for: task.taskIdentifier))
    task.cancel()
    session.invalidateAndCancel()
  }

  func testCancelRemovesRequestCancelsTaskAndCompletesExactlyOnce() {
    let started = expectation(description: "network request started")
    let completed = expectation(description: "cancelled completion")
    let taskStopped = expectation(description: "URLSession task stopped")
    let recorder = CompletionRecorder<RemoteImageResult>()
    var controlledRequest: ControlledURLRequest?
    ControllableURLProtocol.setRequestHandler { request in
      controlledRequest = request
      started.fulfill()
    }
    ControllableURLProtocol.setStopHandler { taskStopped.fulfill() }

    api.requestImage(
      request: makeRequest(
        url: URL(string: "https://photos.example.test/api/assets/1/thumbnail")!,
        origin: "https://photos.example.test",
        policy: .cacheThenNetwork,
        requestId: 6
      )
    ) { result in
      if recorder.record(result) {
        completed.fulfill()
      }
    }

    wait(for: [started], timeout: 1)
    api.cancelRequest(requestId: 6)
    api.cancelRequest(requestId: 6)
    wait(for: [completed, taskStopped], timeout: 1)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertFalse(controlledRequest?.respond(statusCode: 200) ?? true)
    XCTAssertFalse(controlledRequest?.send(Data("late".utf8)) ?? true)
    XCTAssertFalse(controlledRequest?.finish() ?? true)
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(performance.startedCount(.request(.remoteThumbnail)), 1)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 1)
  }

  func testDuplicateRequestReplacesOriginalAndPairsBothSpans() {
    let originalStarted = expectation(description: "original request started")
    let replacementStarted = expectation(description: "replacement request started")
    let originalCompleted = expectation(description: "original request cancelled")
    let replacementCompleted = expectation(description: "replacement request cancelled")
    let original = CompletionRecorder<RemoteImageResult>()
    let replacement = CompletionRecorder<RemoteImageResult>()
    let startCount = Mutex(0)
    ControllableURLProtocol.setRequestHandler { _ in
      let count = startCount.withLock { count in
        count += 1
        return count
      }
      if count == 1 {
        originalStarted.fulfill()
      } else {
        replacementStarted.fulfill()
      }
    }

    let request = makeRequest(
      url: URL(string: "https://photos.example.test/api/assets/duplicate/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheThenNetwork,
      requestId: 70
    )
    api.requestImage(request: request) { result in
      if original.record(result) { originalCompleted.fulfill() }
    }
    wait(for: [originalStarted], timeout: 1)

    api.requestImage(request: request) { result in
      if replacement.record(result) { replacementCompleted.fulfill() }
    }
    wait(for: [originalCompleted, replacementStarted], timeout: 1)

    XCTAssertEqual(try? original.result?.get().error, .cancelled)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 2)
    XCTAssertEqual(performance.startedCount(.request(.remoteThumbnail)), 2)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 1)
    XCTAssertEqual(performance.activeCount(.request(.remoteThumbnail)), 1)

    api.cancelRequest(requestId: 70)
    wait(for: [replacementCompleted], timeout: 1)
    XCTAssertEqual(try? replacement.result?.get().error, .cancelled)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 2)
    XCTAssertEqual(performance.activeCount(.request(.remoteThumbnail)), 0)
  }

  func testReplacementIsInstrumentedBeforeOriginalCompletionCancelsItReentrantly() {
    let originalStarted = expectation(description: "original request started")
    let originalCompleted = expectation(description: "original request cancelled")
    let replacementCompleted = expectation(description: "replacement request cancelled")
    let original = CompletionRecorder<RemoteImageResult>()
    let replacement = CompletionRecorder<RemoteImageResult>()
    ControllableURLProtocol.setRequestHandler { _ in originalStarted.fulfill() }

    let request = makeRequest(
      url: URL(string: "https://photos.example.test/api/assets/reentrant/thumbnail")!,
      origin: "https://photos.example.test",
      policy: .cacheThenNetwork,
      requestId: 71
    )
    api.requestImage(request: request) { [self] result in
      guard original.record(result) else { return }
      api.cancelRequest(requestId: 71)
      originalCompleted.fulfill()
    }
    wait(for: [originalStarted], timeout: 1)

    api.requestImage(request: request) { result in
      if replacement.record(result) { replacementCompleted.fulfill() }
    }
    wait(for: [originalCompleted, replacementCompleted], timeout: 1)

    XCTAssertEqual(try? original.result?.get().error, .cancelled)
    XCTAssertEqual(try? replacement.result?.get().error, .cancelled)
    XCTAssertEqual(performance.startedCount(.request(.remoteThumbnail)), 2)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 2)
    XCTAssertEqual(performance.activeCount(.request(.remoteThumbnail)), 0)
  }

  func testDisposeFinishesRunningRequestSpanExactlyOnce() {
    let started = expectation(description: "request started")
    let completed = expectation(description: "request cancelled by dispose")
    let recorder = CompletionRecorder<RemoteImageResult>()
    ControllableURLProtocol.setRequestHandler { _ in started.fulfill() }

    api.requestImage(
      request: makeRequest(
        url: URL(string: "https://photos.example.test/api/assets/dispose/thumbnail")!,
        origin: "https://photos.example.test",
        policy: .cacheThenNetwork,
        requestId: 71
      )
    ) { result in
      if recorder.record(result) { completed.fulfill() }
    }
    wait(for: [started], timeout: 1)

    api.dispose()
    api.dispose()
    wait(for: [completed], timeout: 1)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(performance.finishedCount(.request(.remoteThumbnail)), 1)
  }

  func testLateOwnedPayloadIsReleasedAfterCancellationWins() {
    let request = RemoteImageOperation(id: 99) { _ in }
    XCTAssertTrue(request.cancel())
    let pointer = malloc(1)!
    var released = false

    let lateCompletionWasAccepted = request.complete(
      .success(
        RemoteImageResult(
          payload: RemoteImagePayload(pointer: Int64(Int(bitPattern: pointer)), length: 1),
          error: nil
        )
      )
    )
    RemoteImagePayloadOwnership.releaseIfUndelivered(
      pointer,
      delivered: lateCompletionWasAccepted,
      release: {
        free($0)
        released = true
      }
    )

    XCTAssertFalse(lateCompletionWasAccepted)
    XCTAssertTrue(released)
  }

  private func request(
    url: URL,
    origin: String,
    policy: RemoteImagePolicy,
    requestId: Int64
  ) -> Result<RemoteImageResult, Error> {
    let completed = expectation(description: "remote image request \(requestId)")
    var captured: Result<RemoteImageResult, Error>?
    api.requestImage(
      request: makeRequest(url: url, origin: origin, policy: policy, requestId: requestId)
    ) { result in
      captured = result
      completed.fulfill()
    }
    wait(for: [completed], timeout: 1)
    return captured ?? .failure(RemoteImageTestError.missingCompletion)
  }

  private func makeRequest(
    url: URL,
    origin: String,
    policy: RemoteImagePolicy,
    requestId: Int64
  ) -> RemoteImageRequest {
    RemoteImageRequest(
      url: url.absoluteString,
      origin: origin,
      requestId: requestId,
      preferEncoded: true,
      policy: policy,
      kind: .thumbnail
    )
  }

  private func assertEncodedPayload(
    _ result: Result<RemoteImageResult, Error>,
    equals expected: Data,
    file: StaticString = #filePath,
    line: UInt = #line
  ) {
    guard let payload = try? result.get().payload else {
      return XCTFail("Expected an encoded payload", file: file, line: line)
    }
    XCTAssertEqual(payload.length, Int64(expected.count), file: file, line: line)
    guard let pointer = UnsafeMutableRawPointer(bitPattern: Int(payload.pointer)) else {
      return XCTFail("Expected a valid payload pointer", file: file, line: line)
    }
    let actual = Data(bytes: pointer, count: expected.count)
    free(pointer)
    XCTAssertEqual(actual, expected, file: file, line: line)
  }
}
