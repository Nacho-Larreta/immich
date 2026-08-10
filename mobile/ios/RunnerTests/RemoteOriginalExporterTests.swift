import Foundation
import XCTest

@testable import Runner

final class RemoteOriginalExporterTests: XCTestCase {
  private var root: URL!
  private var context: URLSessionTestContext!
  private var store: RemoteRecordingFileStore!
  private var leaseRegistry: OriginalExportLeaseRegistry!
  private var exporter: RemoteOriginalExporter!

  override func setUp() {
    super.setUp()
    try! URLSessionManager.replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.example.test",
      token: nil
    )
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    context = URLSessionTestFactory.make()
    store = RemoteRecordingFileStore(root: root)
    let ioExecutor = SerialOriginalExportIOExecutor()
    leaseRegistry = OriginalExportLeaseRegistry(ioExecutor: ioExecutor)
    exporter = RemoteOriginalExporter(
      sessionConfiguration: context.session.configuration,
      fileStore: store,
      ioExecutor: ioExecutor,
      leaseRegistry: leaseRegistry,
      timeout: 30,
      progressHandler: { _ in }
    )
  }

  override func tearDown() {
    exporter.dispose()
    context.reset()
    try? FileManager.default.removeItem(at: root)
    try! URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    exporter = nil
    store = nil
    leaseRegistry = nil
    context = nil
    root = nil
    super.tearDown()
  }

  func testTwoHundredResponseStreamsToCommittedFileWithOnePendingWrite() throws {
    XCTAssertFalse(exporter.usesURLCache)
    store.appendDelay = 0.05
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.respond(statusCode: 200, headers: ["Content-Length": "6"]))
      XCTAssertTrue(request.send(Data("abc".utf8)))
      XCTAssertTrue(request.send(Data("def".utf8)))
      XCTAssertTrue(request.finish())
    }

    let result = try request(id: 1).get()

    let path = try XCTUnwrap(result.path)
    let leaseToken = try XCTUnwrap(result.leaseToken)
    XCTAssertNil(result.error)
    XCTAssertEqual(leaseRegistry.registeredPath(for: leaseToken)?.path, path)
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("abcdef".utf8))
    XCTAssertEqual(store.openCount, 1)
    XCTAssertEqual(exporter.peakPendingWriteCount, 1)
  }

  func testLeaseReleaseDeletesOnlyRegisteredCommittedFileAndIsExactOnce() throws {
    ControllableURLProtocol.setRequestHandler(Self.sendSuccessfulResponse)
    let result = try request(id: 2).get()
    let path = try XCTUnwrap(result.path)
    let token = try XCTUnwrap(result.leaseToken)
    let released = expectation(description: "registered lease released")

    leaseRegistry.release(token: token) { releaseResult in
      XCTAssertNil(releaseResult.error)
      XCTAssertFalse(FileManager.default.fileExists(atPath: path))
      released.fulfill()
    }
    wait(for: [released], timeout: 1)
    XCTAssertEqual(store.removeCount, 1)

    let repeated = expectation(description: "repeated token rejected")
    leaseRegistry.release(token: token) { releaseResult in
      XCTAssertEqual(releaseResult.error, .leaseNotFound)
      repeated.fulfill()
    }
    wait(for: [repeated], timeout: 1)
    XCTAssertEqual(store.removeCount, 1)

    let unknown = expectation(description: "unknown token rejected")
    leaseRegistry.release(token: path) { releaseResult in
      XCTAssertEqual(releaseResult.error, .leaseNotFound)
      unknown.fulfill()
    }
    wait(for: [unknown], timeout: 1)
    XCTAssertEqual(store.removeCount, 1)
  }

  func testUnauthorizedAndOtherHttpFailuresDoNotOpenPartFile() throws {
    for (index, status) in [401, 503].enumerated() {
      ControllableURLProtocol.setRequestHandler { request in
        XCTAssertTrue(request.respond(statusCode: status))
        _ = request.finish()
      }
      let result = try request(id: Int64(10 + index)).get()
      XCTAssertEqual(result.error, status == 401 ? .unauthorized : .httpFailure)
    }
    XCTAssertEqual(store.openCount, 0)
    XCTAssertEqual(store.removeCount, 2)
  }

  func testOriginMismatchAndUserInfoAreRejectedBeforeNetwork() throws {
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("Invalid remote exports must not start URLSession")
    }

    let mismatch = try request(
      id: 20,
      url: "https://other.example.test/api/assets/1/original"
    ).get()
    let userInfo = try request(
      id: 21,
      url: "https://user@photos.example.test/api/assets/1/original"
    ).get()

    XCTAssertEqual(mismatch.error, .wrongServer)
    XCTAssertEqual(userInfo.error, .wrongServer)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
    XCTAssertTrue(store.destinations.isEmpty)
  }

  func testSelfDeclaredRogueOriginIsRejectedAgainstActiveNetworkContext() throws {
    ControllableURLProtocol.setRequestHandler { _ in
      XCTFail("A self-declared rogue origin must not create a URLSession task")
    }

    let result = try request(
      id: 22,
      url: "https://evil.example.test/api/assets/1/original",
      origin: "https://evil.example.test"
    ).get()

    XCTAssertEqual(result.error, .wrongServer)
    XCTAssertTrue(ControllableURLProtocol.observedRequests.isEmpty)
    XCTAssertTrue(store.destinations.isEmpty)
  }

  func testRequestForwardsOnlyExactHostCookiesAndConfiguredHeaders() throws {
    context.cookieStorage.setCookie(
      HTTPCookie(
        properties: [
          .domain: "photos.example.test",
          .name: "same_host",
          .path: "/",
          .secure: "TRUE",
          .value: "expected",
        ]
      )!
    )
    context.cookieStorage.setCookie(
      HTTPCookie(
        properties: [
          .domain: "other.example.test",
          .name: "secret",
          .path: "/",
          .secure: "TRUE",
          .value: "must-not-leak",
        ]
      )!
    )
    try URLSessionManager.replaceRequestContext(
      headers: ["X-Immich-Context": "expected"],
      canonicalOrigin: "https://photos.example.test",
      token: nil
    )
    exporter.dispose()
    exporter = RemoteOriginalExporter(
      sessionConfiguration: context.session.configuration,
      fileStore: store,
      timeout: 30,
      progressHandler: { _ in }
    )
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertEqual(request.request?.cachePolicy, .reloadIgnoringLocalCacheData)
      let cookie = request.request?.value(forHTTPHeaderField: "Cookie") ?? ""
      XCTAssertTrue(cookie.contains("same_host=expected"))
      XCTAssertFalse(cookie.contains("must-not-leak"))
      XCTAssertEqual(request.request?.value(forHTTPHeaderField: "X-Immich-Context"), "expected")
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data("ok".utf8)))
      XCTAssertTrue(request.finish())
    }

    XCTAssertNotNil(try request(id: 30).get().path)
  }

  func testCancellationStopsTaskDeletesPartAndIgnoresLateCallbacks() {
    let started = expectation(description: "request started")
    let stopped = expectation(description: "task stopped")
    let completed = expectation(description: "completion")
    let recorder = CompletionRecorder<OriginalExportResult>()
    var controlled: ControlledURLRequest?
    ControllableURLProtocol.setRequestHandler { request in
      controlled = request
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data("partial".utf8)))
      started.fulfill()
    }
    ControllableURLProtocol.setStopHandler { stopped.fulfill() }

    exporter.export(request: makeRequest(id: 40)) { result in
      if recorder.record(result) { completed.fulfill() }
    }
    wait(for: [started], timeout: 1)
    let cancelReturned = expectation(description: "cancel barrier returned after cleanup")
    exporter.cancel(requestId: 40) {
      XCTAssertFalse(
        FileManager.default.fileExists(atPath: self.store.destinations[0].directory.path)
      )
      cancelReturned.fulfill()
    }
    exporter.cancel(requestId: 40)
    wait(for: [completed, stopped, cancelReturned], timeout: 1)

    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
    XCTAssertFalse(controlled?.send(Data("late".utf8)) ?? true)
    XCTAssertFalse(controlled?.finish() ?? true)
    XCTAssertEqual(recorder.count, 1)
  }

  func testInvalidationTimeoutCancelsActiveExport() throws {
    let started = expectation(description: "remote export started")
    let completed = expectation(description: "remote export cancelled")
    let recorder = CompletionRecorder<OriginalExportResult>()
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.respond(statusCode: 200, headers: ["Content-Length": "12"]))
      XCTAssertTrue(request.send(Data("partial".utf8)))
      started.fulfill()
    }

    exporter.export(
      request: RemoteOriginalExportRequest(
        requestId: 41,
        url: "https://photos.example.test/api/assets/1/original",
        origin: "https://photos.example.test",
        suggestedName: "photo.jpg"
      )
    ) { result in
      recorder.record(result)
      completed.fulfill()
    }
    wait(for: [started], timeout: 1)

    URLSessionManager.overrideSessionInvalidationBarrierForTesting { false }
    defer { URLSessionManager.overrideSessionInvalidationBarrierForTesting(nil) }
    XCTAssertThrowsError(
      try URLSessionManager.replaceRequestContext(
        headers: [:],
        canonicalOrigin: "https://photos.example.test",
        token: "replacement-token"
      )
    )

    wait(for: [completed], timeout: 1)
    XCTAssertEqual(try recorder.result?.get().error, .cancelled)
    XCTAssertTrue(
      store.destinations.allSatisfy {
        !FileManager.default.fileExists(atPath: $0.part.path)
          && !FileManager.default.fileExists(atPath: $0.committed.path)
      }
    )
  }

  func testDiskOpenFailureIsTypedAndCleansLease() throws {
    store.openFailure = .storageUnavailable
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.respond(statusCode: 200))
      _ = request.finish()
    }

    let result = try request(id: 50).get()

    XCTAssertEqual(result.error, .storageUnavailable)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testCrossOriginRedirectIsRejectedAndCleansLease() throws {
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(
        request.redirect(to: URL(string: "https://evil.example.test/stolen-original")!)
      )
    }

    let result = try request(id: 51).get()

    XCTAssertEqual(result.error, .wrongServer)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testAppendCommitAndCleanupFailuresAreTypedAndCompleteAfterCleanup() throws {
    store.appendFailure = .writeFailed
    ControllableURLProtocol.setRequestHandler(Self.sendSuccessfulResponse)
    XCTAssertEqual(try request(id: 52).get().error, .writeFailed)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))

    store.appendFailure = nil
    store.commitFailure = .writeFailed
    ControllableURLProtocol.setRequestHandler(Self.sendSuccessfulResponse)
    XCTAssertEqual(try request(id: 53).get().error, .writeFailed)
    XCTAssertEqual(store.removeCount, 2)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[1].directory.path))

    store.commitFailure = nil
    store.removeFailure = .cleanupFailed
    ControllableURLProtocol.setRequestHandler { request in
      XCTAssertTrue(request.respond(statusCode: 503))
      _ = request.finish()
    }
    XCTAssertEqual(try request(id: 54).get().error, .cleanupFailed)
    XCTAssertEqual(store.removeCount, 3)
  }

  func testTimeoutCancelsTaskCleansPartAndIgnoresLateCallbacks() {
    let scheduler = RemoteManualTimeoutScheduler()
    replaceExporter(scheduler: scheduler)
    let started = expectation(description: "remote timeout request started")
    let stopped = expectation(description: "remote timeout task stopped")
    let completed = expectation(description: "remote timeout completion")
    let recorder = CompletionRecorder<OriginalExportResult>()
    var controlled: ControlledURLRequest?
    ControllableURLProtocol.setRequestHandler { request in
      controlled = request
      XCTAssertTrue(request.respond(statusCode: 200))
      XCTAssertTrue(request.send(Data("partial".utf8)))
      started.fulfill()
    }
    ControllableURLProtocol.setStopHandler { stopped.fulfill() }
    exporter.export(request: makeRequest(id: 55)) { result in
      XCTAssertEqual(self.store.removeCount, 1)
      _ = recorder.record(result)
      completed.fulfill()
    }
    wait(for: [started], timeout: 1)

    scheduler.fireAll()

    wait(for: [completed, stopped], timeout: 1)
    XCTAssertEqual(try? recorder.result?.get().error, .timeout)
    XCTAssertEqual(recorder.count, 1)
    XCTAssertFalse(controlled?.send(Data("late".utf8)) ?? true)
    XCTAssertFalse(controlled?.finish() ?? true)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testRemotePoolStartsAtMostTwoAndQueuedCancellationCreatesNoTaskOrLease() {
    let started = expectation(description: "two remote tasks started")
    started.expectedFulfillmentCount = 2
    ControllableURLProtocol.setRequestHandler { _ in started.fulfill() }
    let first = startRequest(id: 60)
    let second = startRequest(id: 61)
    let queued = startRequest(id: 62)

    wait(for: [started], timeout: 1)
    XCTAssertEqual(exporter.activeCount, 2)
    XCTAssertEqual(exporter.peakActiveCount, 2)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 2)
    XCTAssertEqual(store.destinations.count, 2)
    XCTAssertEqual(Set(store.destinations.map(\.directory)).count, 2)

    exporter.cancel(requestId: 62)
    waitForCompletion(queued)
    XCTAssertEqual(try? queued.result?.get().error, .cancelled)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 2)
    XCTAssertEqual(store.destinations.count, 2)

    let cancelledAll = expectation(description: "cancel all barrier")
    exporter.cancelAll {
      XCTAssertEqual(self.store.removeCount, 2)
      XCTAssertTrue(
        self.store.destinations.allSatisfy {
          !FileManager.default.fileExists(atPath: $0.directory.path)
        }
      )
      cancelledAll.fulfill()
    }
    waitForCompletion(first)
    waitForCompletion(second)
    wait(for: [cancelledAll], timeout: 1)
    waitUntil { self.exporter.activeCount == 0 }
    XCTAssertEqual(try? first.result?.get().error, .cancelled)
    XCTAssertEqual(try? second.result?.get().error, .cancelled)
  }

  func testDisposeIsIdempotentRejectsNewRequestsAndRequestIdCanBeReusedAfterTerminal() throws {
    ControllableURLProtocol.setRequestHandler(Self.sendSuccessfulResponse)
    XCTAssertNotNil(try request(id: 70).get().path)
    ControllableURLProtocol.setRequestHandler(Self.sendSuccessfulResponse)
    XCTAssertNotNil(try request(id: 70).get().path)
    XCTAssertEqual(store.destinations.count, 2)

    let started = expectation(description: "active request before dispose")
    ControllableURLProtocol.setRequestHandler { _ in started.fulfill() }
    let active = startRequest(id: 71)
    wait(for: [started], timeout: 1)
    let disposed = expectation(description: "dispose barrier")
    exporter.dispose { disposed.fulfill() }
    let repeatedDispose = expectation(description: "repeated dispose")
    exporter.dispose { repeatedDispose.fulfill() }
    waitForCompletion(active)
    wait(for: [disposed, repeatedDispose], timeout: 1)
    XCTAssertEqual(try? active.result?.get().error, .cancelled)

    let rejected = startRequest(id: 72)
    waitForCompletion(rejected)
    XCTAssertEqual(try? rejected.result?.get().error, .cancelled)
  }

  private func request(
    id: Int64,
    url: String = "https://photos.example.test/api/assets/1/original",
    origin: String = "https://photos.example.test"
  ) throws -> Result<OriginalExportResult, Error> {
    let completed = expectation(description: "remote original export \(id)")
    var captured: Result<OriginalExportResult, Error>?
    exporter.export(request: makeRequest(id: id, url: url, origin: origin)) {
      captured = $0
      completed.fulfill()
    }
    wait(for: [completed], timeout: 1)
    return try XCTUnwrap(captured)
  }

  private func makeRequest(
    id: Int64,
    url: String = "https://photos.example.test/api/assets/1/original",
    origin: String = "https://photos.example.test"
  ) -> RemoteOriginalExportRequest {
    RemoteOriginalExportRequest(
      requestId: id,
      url: url,
      origin: origin,
      suggestedName: "asset.jpg"
    )
  }

  private func startRequest(id: Int64) -> CompletionRecorder<OriginalExportResult> {
    let recorder = CompletionRecorder<OriginalExportResult>()
    exporter.export(request: makeRequest(id: id)) { result in
      _ = recorder.record(result)
    }
    return recorder
  }

  private func replaceExporter(
    scheduler: any OriginalExportTimeoutScheduling = DispatchOriginalExportTimeoutScheduler()
  ) {
    exporter.dispose()
    exporter = RemoteOriginalExporter(
      sessionConfiguration: context.session.configuration,
      fileStore: store,
      scheduler: scheduler,
      leaseRegistry: leaseRegistry,
      timeout: 30,
      progressHandler: { _ in }
    )
  }

  private func waitForCompletion(_ recorder: CompletionRecorder<OriginalExportResult>) {
    waitUntil { recorder.count == 1 }
    XCTAssertEqual(recorder.count, 1)
  }

  private func waitUntil(_ predicate: @escaping () -> Bool) {
    let deadline = Date().addingTimeInterval(1)
    while !predicate(), RunLoop.current.run(mode: .default, before: deadline), Date() < deadline {}
  }

  private static func sendSuccessfulResponse(_ request: ControlledURLRequest) {
    XCTAssertTrue(request.respond(statusCode: 200))
    XCTAssertTrue(request.send(Data("original".utf8)))
    XCTAssertTrue(request.finish())
  }
}

private final class RemoteRecordingFileStore: OriginalExportFileStoring {
  init(root: URL) {
    self.store = TemporaryOriginalExportFileStore(temporaryDirectory: root)
  }

  private let store: TemporaryOriginalExportFileStore
  var openFailure: OriginalExportFailure?
  var appendFailure: OriginalExportFailure?
  var appendDelay: TimeInterval = 0
  var commitFailure: OriginalExportFailure?
  var removeFailure: OriginalExportFailure?
  private(set) var destinations: [OriginalExportDestination] = []
  private(set) var openCount = 0
  private(set) var removeCount = 0

  func createDestination(suggestedName: String) throws -> OriginalExportDestination {
    XCTAssertFalse(Thread.isMainThread)
    let destination = try store.createDestination(suggestedName: suggestedName)
    destinations.append(destination)
    return destination
  }

  func openPart(
    at destination: OriginalExportDestination
  ) throws -> any OriginalExportFileWriting {
    XCTAssertFalse(Thread.isMainThread)
    openCount += 1
    if let openFailure { throw openFailure }
    return RemoteThreadCheckingFile(
      file: try store.openPart(at: destination),
      appendFailure: appendFailure,
      appendDelay: appendDelay
    )
  }

  func commit(_ destination: OriginalExportDestination) throws -> URL {
    XCTAssertFalse(Thread.isMainThread)
    if let commitFailure { throw commitFailure }
    return try store.commit(destination)
  }

  func remove(_ destination: OriginalExportDestination) throws {
    XCTAssertFalse(Thread.isMainThread)
    removeCount += 1
    if let removeFailure { throw removeFailure }
    try store.remove(destination)
  }
}

private final class RemoteThreadCheckingFile: OriginalExportFileWriting {
  init(
    file: any OriginalExportFileWriting,
    appendFailure: OriginalExportFailure?,
    appendDelay: TimeInterval
  ) {
    self.file = file
    self.appendFailure = appendFailure
    self.appendDelay = appendDelay
  }

  private let file: any OriginalExportFileWriting
  private let appendFailure: OriginalExportFailure?
  private let appendDelay: TimeInterval

  func write(contentsOf data: Data) throws {
    XCTAssertFalse(Thread.isMainThread)
    if let appendFailure { throw appendFailure }
    if appendDelay > 0 { Thread.sleep(forTimeInterval: appendDelay) }
    try file.write(contentsOf: data)
  }

  func close() throws {
    XCTAssertFalse(Thread.isMainThread)
    try file.close()
  }
}

private final class RemoteManualTimeoutScheduler: OriginalExportTimeoutScheduling {
  private final class Task: OriginalExportScheduledTask {
    var isCancelled = false
    func cancel() { isCancelled = true }
  }

  private var entries: [(Task, @Sendable () -> Void)] = []

  func schedule(
    after delay: TimeInterval,
    action: @escaping @Sendable () -> Void
  ) -> any OriginalExportScheduledTask {
    let task = Task()
    entries.append((task, action))
    return task
  }

  func fireAll() {
    let pending = entries
    entries.removeAll()
    for (task, action) in pending where !task.isCancelled {
      action()
    }
  }
}
