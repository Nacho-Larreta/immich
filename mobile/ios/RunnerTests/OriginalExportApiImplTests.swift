import XCTest

@testable import Runner

final class OriginalExportApiImplTests: XCTestCase {
  private var localExporter: ControllableLocalOriginalExporter!
  private var remoteExporter: ControllableRemoteOriginalExporter!
  private var performance: RecordingPerformanceRecorder!
  private var api: OriginalExportApiImpl!

  override func setUp() {
    super.setUp()
    localExporter = ControllableLocalOriginalExporter()
    remoteExporter = ControllableRemoteOriginalExporter()
    performance = RecordingPerformanceRecorder()
    api = OriginalExportApiImpl(
      localExporter: localExporter,
      remoteExporter: remoteExporter,
      leaseRegistry: OriginalExportLeaseRegistry(ioExecutor: ImmediateOriginalExportIOExecutor()),
      performanceRecorder: performance
    )
  }

  override func tearDown() {
    api = nil
    performance = nil
    remoteExporter = nil
    localExporter = nil
    super.tearDown()
  }

  func testLocalAndRemoteResultsFinishTheirAcceptedRequestSpans() {
    let local = CompletionRecorder<OriginalExportResult>()
    let remote = CompletionRecorder<OriginalExportResult>()

    api.exportLocal(request: makeLocalRequest(id: 1)) { _ = local.record($0) }
    api.exportRemote(request: makeRemoteRequest(id: 2)) { _ = remote.record($0) }

    XCTAssertEqual(performance.activeCount(.request(.localOriginalExport)), 1)
    XCTAssertEqual(performance.activeCount(.request(.remoteOriginalExport)), 1)

    localExporter.complete(
      requestId: 1,
      result: OriginalExportResult(path: nil, leaseToken: nil, error: nil)
    )
    remoteExporter.complete(
      requestId: 2,
      result: .failure(.serverUnavailable)
    )

    XCTAssertEqual(local.count, 1)
    XCTAssertEqual(remote.count, 1)
    XCTAssertEqual(performance.finishedCount(.request(.localOriginalExport)), 1)
    XCTAssertEqual(performance.finishedCount(.request(.remoteOriginalExport)), 1)
  }

  func testDuplicateRequestIsRejectedWithoutStartingOrFinishingAnotherSpan() {
    let original = CompletionRecorder<OriginalExportResult>()
    let duplicate = CompletionRecorder<OriginalExportResult>()
    let request = makeLocalRequest(id: 3)

    api.exportLocal(request: request) { _ = original.record($0) }
    api.exportLocal(request: request) { _ = duplicate.record($0) }

    XCTAssertEqual(localExporter.exportCount, 1)
    XCTAssertEqual(try? duplicate.result?.get().error, .cancelled)
    XCTAssertEqual(performance.startedCount(.request(.localOriginalExport)), 1)
    XCTAssertEqual(performance.activeCount(.request(.localOriginalExport)), 1)

    localExporter.complete(requestId: 3, result: .failure(.mediaNotLocal))

    XCTAssertEqual(original.count, 1)
    XCTAssertEqual(performance.finishedCount(.request(.localOriginalExport)), 1)
  }

  func testCancelRequestFinishesTheRunningRequestSpanExactlyOnce() {
    let request = CompletionRecorder<OriginalExportResult>()
    let cancelled = expectation(description: "cancel request completed")
    api.exportLocal(request: makeLocalRequest(id: 4)) { _ = request.record($0) }

    api.cancelRequest(requestId: 4) { result in
      if case .failure = result { XCTFail("Expected cancellation to complete") }
      cancelled.fulfill()
    }
    wait(for: [cancelled], timeout: 1)

    XCTAssertEqual(try? request.result?.get().error, .cancelled)
    XCTAssertEqual(performance.finishedCount(.request(.localOriginalExport)), 1)
    localExporter.complete(requestId: 4, result: .failure(.mediaNotLocal))
    XCTAssertEqual(request.count, 1)
  }

  func testDisposeFinishesEveryActiveRequestSpanAndIsIdempotent() {
    let local = CompletionRecorder<OriginalExportResult>()
    let remote = CompletionRecorder<OriginalExportResult>()
    let disposed = expectation(description: "dispose completed")
    api.exportLocal(request: makeLocalRequest(id: 5)) { _ = local.record($0) }
    api.exportRemote(request: makeRemoteRequest(id: 6)) { _ = remote.record($0) }

    api.dispose { result in
      if case .failure = result { XCTFail("Expected dispose to complete") }
      disposed.fulfill()
    }
    wait(for: [disposed], timeout: 1)

    XCTAssertEqual(try? local.result?.get().error, .cancelled)
    XCTAssertEqual(try? remote.result?.get().error, .cancelled)
    XCTAssertEqual(performance.finishedCount(.request(.localOriginalExport)), 1)
    XCTAssertEqual(performance.finishedCount(.request(.remoteOriginalExport)), 1)
  }

  private func makeLocalRequest(id: Int64) -> LocalOriginalExportRequest {
    LocalOriginalExportRequest(
      requestId: id,
      assetId: "asset",
      suggestedName: "original",
      policy: .localOnly
    )
  }

  private func makeRemoteRequest(id: Int64) -> RemoteOriginalExportRequest {
    let identity = URLSessionManager.requestContextIdentity()
    return RemoteOriginalExportRequest(
      requestId: id,
      url: "https://example.test/original",
      origin: "https://example.test",
      apiEndpoint: "https://example.test/api",
      sessionEpoch: identity.sessionEpoch,
      expectedContextGeneration: identity.generation,
      schemePolicy: .httpsOnly,
      suggestedName: "original"
    )
  }
}

private final class ImmediateOriginalExportIOExecutor: OriginalExportIOExecuting {
  func execute(_ action: @escaping @Sendable () -> Void) {
    action()
  }
}

private final class ControllableLocalOriginalExporter: LocalOriginalExporting {
  private var completions: [Int64: (Result<OriginalExportResult, any Error>) -> Void] = [:]
  private(set) var exportCount = 0

  func export(
    request: LocalOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    exportCount += 1
    completions[request.requestId] = completion
  }

  func cancel(requestId: Int64, completion: @escaping () -> Void) {
    complete(requestId: requestId, result: .failure(.cancelled))
    completion()
  }

  func cancelAll(completion: @escaping () -> Void) {
    for requestId in Array(completions.keys) {
      complete(requestId: requestId, result: .failure(.cancelled))
    }
    completion()
  }

  func dispose(completion: @escaping () -> Void) {
    cancelAll(completion: completion)
  }

  func complete(requestId: Int64, result: OriginalExportResult) {
    completions.removeValue(forKey: requestId)?(.success(result))
  }
}

private final class ControllableRemoteOriginalExporter: RemoteOriginalExporting {
  private var completions: [Int64: (Result<OriginalExportResult, any Error>) -> Void] = [:]

  func export(
    request: RemoteOriginalExportRequest,
    completion: @escaping (Result<OriginalExportResult, any Error>) -> Void
  ) {
    completions[request.requestId] = completion
  }

  func cancel(requestId: Int64, completion: @escaping () -> Void) {
    complete(requestId: requestId, result: .failure(.cancelled))
    completion()
  }

  func cancelAll(completion: @escaping () -> Void) {
    for requestId in Array(completions.keys) {
      complete(requestId: requestId, result: .failure(.cancelled))
    }
    completion()
  }

  func dispose(completion: @escaping () -> Void) {
    cancelAll(completion: completion)
  }

  func complete(requestId: Int64, result: OriginalExportResult) {
    completions.removeValue(forKey: requestId)?(.success(result))
  }
}
