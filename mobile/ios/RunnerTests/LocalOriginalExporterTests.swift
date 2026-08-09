import Foundation
import Photos
import XCTest

@testable import Runner

final class LocalOriginalExporterTests: XCTestCase {
  private var root: URL!
  private var store: RecordingOriginalExportFileStore!
  private var provider: ControllableOriginalResourceProvider!
  private var scheduler: ManualOriginalExportTimeoutScheduler!
  private var progress: [OriginalExportProgress]!
  private var pool: OriginalExportPermitPool!
  private var exporter: LocalOriginalExporter!

  override func setUp() {
    super.setUp()
    root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try! FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    store = RecordingOriginalExportFileStore(root: root)
    provider = ControllableOriginalResourceProvider()
    scheduler = ManualOriginalExportTimeoutScheduler()
    progress = []
    pool = OriginalExportPermitPool(limit: 2)
    exporter = LocalOriginalExporter(
      provider: provider,
      fileStore: store,
      scheduler: scheduler,
      pool: pool,
      deadlines: .init(local: 2, iCloud: 5),
      progressHandler: { [weak self] in self?.progress.append($0) }
    )
  }

  override func tearDown() {
    exporter.dispose()
    try? FileManager.default.removeItem(at: root)
    exporter = nil
    progress = nil
    pool = nil
    scheduler = nil
    provider = nil
    store = nil
    root = nil
    super.tearDown()
  }

  func testLocalOnlyDisablesNetworkAndReturnsCommittedPath() throws {
    let recorder = request(id: 1, policy: .localOnly, suggestedName: "../photo.jpg")
    provider.waitUntilStarted(count: 1)

    XCTAssertEqual(provider.requests[0].allowsNetworkAccess, false)
    XCTAssertNil(provider.requests[0].progress)
    provider.send(Data("original".utf8), at: 0)
    provider.complete(at: 0)
    waitForCompletion(recorder)

    let result = try XCTUnwrap(recorder.result?.get())
    let path = try XCTUnwrap(result.path)
    XCTAssertNil(result.error)
    XCTAssertEqual(URL(fileURLWithPath: path).lastPathComponent, "photo.jpg")
    XCTAssertEqual(try Data(contentsOf: URL(fileURLWithPath: path)), Data("original".utf8))
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].part.path))
  }

  func testAllowICloudEnablesNetworkAndForwardsProgress() throws {
    let recorder = request(id: 2, policy: .allowICloud)
    provider.waitUntilStarted(count: 1)

    XCTAssertTrue(provider.requests[0].allowsNetworkAccess)
    provider.reportProgress(0.25, at: 0)
    provider.send(Data("cloud".utf8), at: 0)
    provider.complete(at: 0)
    waitForCompletion(recorder)

    XCTAssertNotNil(try recorder.result?.get().path)
    XCTAssertEqual(progress, [OriginalExportProgress(requestId: 2, fraction: 0.25)])
  }

  func testICloudFailureIsTypedAndDeletesPartialFile() {
    let recorder = request(id: 22, policy: .allowICloud)
    provider.waitUntilStarted(count: 1)
    provider.send(Data("partial".utf8), at: 0)

    provider.complete(with: OriginalExportFailure.iCloudUnavailable, at: 0)
    waitForCompletion(recorder)

    XCTAssertEqual(try? recorder.result?.get().error, .iCloudUnavailable)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testMissingAssetFailsWithoutCreatingLease() {
    provider.resolution = .failure(.assetMissing)
    let recorder = request(id: 3)
    waitForCompletion(recorder)

    XCTAssertEqual(try? recorder.result?.get().error, .assetMissing)
    XCTAssertTrue(store.destinations.isEmpty)
  }

  func testAssetWithoutOriginalResourceMapsToMediaNotLocal() {
    provider.resolution = .failure(.mediaNotLocal)
    let recorder = request(id: 31)
    waitForCompletion(recorder)

    XCTAssertEqual(try? recorder.result?.get().error, .mediaNotLocal)
    XCTAssertTrue(store.destinations.isEmpty)
  }

  func testCancellationBeforeNativeIdAttachCancelsAndDeletesPartExactlyOnce() {
    let cancelReturned = expectation(description: "cancel barrier after cleanup")
    provider.beforeReturningRequestId = { [weak self] _ in
      self?.exporter.cancel(requestId: 4) { cancelReturned.fulfill() }
    }
    let recorder = request(id: 4)
    provider.waitUntilStarted(count: 1)
    waitForCompletion(recorder)
    wait(for: [cancelReturned], timeout: 1)

    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(provider.cancelledIds, [provider.requests[0].id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
    XCTAssertEqual(store.removeCount, 1)

    provider.complete(at: 0)
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(store.removeCount, 1)
  }

  func testCancellationBetweenDestinationCreationAndWriterAttachCleansBeforeCompletion() {
    let completed = expectation(description: "cancelled after destination creation")
    let recorder = CompletionRecorder<OriginalExportResult>()
    store.onCreate = { [weak self] in self?.exporter.cancel(requestId: 41) }

    exporter.export(
      request: LocalOriginalExportRequest(
        requestId: 41,
        assetId: "asset-41",
        suggestedName: "asset.heic",
        policy: .localOnly
      )
    ) { [weak self] result in
      XCTAssertEqual(self?.store.removeCount, 1)
      _ = recorder.record(result)
      completed.fulfill()
    }

    wait(for: [completed], timeout: 1)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
    XCTAssertTrue(provider.requests.isEmpty)
  }

  func testTimeoutCancelsNativeRequestAndDeletesPartialFile() {
    let recorder = request(id: 5)
    provider.waitUntilStarted(count: 1)
    provider.send(Data("partial".utf8), at: 0)

    scheduler.fireAll()
    waitForCompletion(recorder)

    XCTAssertEqual(try? recorder.result?.get().error, .timeout)
    XCTAssertEqual(provider.cancelledIds, [provider.requests[0].id])
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testCancellationDuringBlockedAppendWaitsForWriterThenCompletesBarrier() {
    let appendStarted = DispatchSemaphore(value: 0)
    let releaseAppend = DispatchSemaphore(value: 0)
    store.beforeAppend = {
      appendStarted.signal()
      releaseAppend.wait()
    }
    let recorder = request(id: 6)
    provider.waitUntilStarted(count: 1)
    let sendFinished = expectation(description: "serial PhotoKit callback returned")
    DispatchQueue.global(qos: .userInitiated).async { [provider] in
      provider?.send(Data("blocked".utf8), at: 0)
      sendFinished.fulfill()
    }
    XCTAssertEqual(appendStarted.wait(timeout: .now() + 1), .success)
    let cancelReturned = expectation(description: "cancel waits for writer cleanup")
    let barrierState = Mutex(false)

    exporter.cancel(requestId: 6) {
      barrierState.withLock { $0 = true }
      cancelReturned.fulfill()
    }
    XCTAssertFalse(barrierState.withLock { $0 })
    releaseAppend.signal()

    wait(for: [sendFinished, cancelReturned], timeout: 1)
    waitForCompletion(recorder)
    XCTAssertEqual(try? recorder.result?.get().error, .cancelled)
    XCTAssertEqual(provider.cancelledIds, [provider.requests[0].id])
    XCTAssertEqual(provider.peakActiveCallbacks, 1)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))

    provider.send(Data("late".utf8), at: 0)
    provider.complete(at: 0)
    XCTAssertEqual(recorder.count, 1)
    XCTAssertEqual(store.removeCount, 1)
  }

  func testSynchronousAppendFailureCancelsNativeRequestAndCleansLease() {
    store.appendFailure = .writeFailed
    let recorder = request(id: 7)
    provider.waitUntilStarted(count: 1)

    provider.send(Data("cannot-write".utf8), at: 0)
    waitForCompletion(recorder)

    XCTAssertEqual(try? recorder.result?.get().error, .writeFailed)
    XCTAssertEqual(provider.cancelledIds, [provider.requests[0].id])
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testUnexpectedMainThreadDataCallbackFailsClosedBeforeWriting() {
    let recorder = request(id: 8)
    provider.waitUntilStarted(count: 1)

    provider.requests[0].dataReceived(Data("must-not-write".utf8))
    waitForCompletion(recorder)

    XCTAssertEqual(try? recorder.result?.get().error, .writeFailed)
    XCTAssertEqual(provider.cancelledIds, [provider.requests[0].id])
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: store.destinations[0].directory.path))
  }

  func testAtMostTwoExportsRunAndQueuedCancellationNeverStartsPhotoKit() {
    let first = request(id: 10)
    let second = request(id: 11)
    let queued = request(id: 12)
    provider.waitUntilStarted(count: 2)

    XCTAssertEqual(exporter.activeCount, 2)
    XCTAssertEqual(exporter.peakActiveCount, 2)
    exporter.cancel(requestId: 12)
    waitForCompletion(queued)
    XCTAssertEqual(try? queued.result?.get().error, .cancelled)
    XCTAssertEqual(provider.requests.count, 2)

    provider.complete(with: OriginalExportFailure.mediaNotLocal, at: 0)
    provider.complete(with: OriginalExportFailure.mediaNotLocal, at: 1)
    waitForCompletion(first)
    waitForCompletion(second)
    XCTAssertEqual(first.count, 1)
    XCTAssertEqual(second.count, 1)
  }

  func testGlobalPoolLimitsMixedLocalAndRemoteExportsAndQueuedCancelStartsNothing() {
    try! URLSessionManager.replaceRequestContext(
      headers: [:],
      canonicalOrigin: "https://photos.example.test",
      token: nil
    )
    let network = URLSessionTestFactory.make()
    defer {
      network.reset()
      try! URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    }
    let remote = RemoteOriginalExporter(
      sessionConfiguration: network.session.configuration,
      fileStore: store,
      pool: pool,
      timeout: 30,
      progressHandler: { _ in }
    )
    let remoteStarted = expectation(description: "remote export owns shared permit")
    ControllableURLProtocol.setRequestHandler { _ in remoteStarted.fulfill() }
    let local = request(id: 100)
    provider.waitUntilStarted(count: 1)
    let remoteResult = CompletionRecorder<OriginalExportResult>()
    remote.export(
      request: RemoteOriginalExportRequest(
        requestId: 101,
        url: "https://photos.example.test/api/assets/101/original",
        origin: "https://photos.example.test",
        suggestedName: "remote.jpg"
      )
    ) { _ = remoteResult.record($0) }
    wait(for: [remoteStarted], timeout: 1)
    let queued = request(id: 102)

    XCTAssertEqual(pool.activeCount, 2)
    XCTAssertEqual(pool.peakActiveCount, 2)
    XCTAssertEqual(provider.requests.count, 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)
    let queuedCancelled = expectation(description: "queued mixed export cancelled")
    exporter.cancel(requestId: 102) { queuedCancelled.fulfill() }
    wait(for: [queuedCancelled], timeout: 1)
    waitForCompletion(queued)
    XCTAssertEqual(try? queued.result?.get().error, .cancelled)
    XCTAssertEqual(provider.requests.count, 1)
    XCTAssertEqual(ControllableURLProtocol.observedRequests.count, 1)

    let localCancelled = expectation(description: "local active export cancelled")
    exporter.cancel(requestId: 100) { localCancelled.fulfill() }
    let remoteCancelled = expectation(description: "remote active export cancelled")
    remote.cancel(requestId: 101) { remoteCancelled.fulfill() }
    wait(for: [localCancelled, remoteCancelled], timeout: 1)
    waitForCompletion(local)
    waitForCompletion(remoteResult)
    XCTAssertEqual(pool.activeCount, 0)
    remote.dispose()
  }

  @discardableResult
  private func request(
    id: Int64,
    policy: OriginalExportPolicy = .localOnly,
    suggestedName: String = "asset.heic"
  ) -> CompletionRecorder<OriginalExportResult> {
    let recorder = CompletionRecorder<OriginalExportResult>()
    exporter.export(
      request: LocalOriginalExportRequest(
        requestId: id,
        assetId: "asset-\(id)",
        suggestedName: suggestedName,
        policy: policy
      ),
      completion: { result in
        _ = recorder.record(result)
      }
    )
    return recorder
  }

  private func waitForCompletion(_ recorder: CompletionRecorder<OriginalExportResult>) {
    let deadline = Date().addingTimeInterval(1)
    while recorder.count == 0, RunLoop.current.run(mode: .default, before: deadline),
      Date() < deadline
    {}
    XCTAssertEqual(recorder.count, 1)
  }
}

private final class ControllableOriginalResourceProvider: LocalOriginalResourceProviding {
  struct Request {
    let id: PHAssetResourceDataRequestID
    let allowsNetworkAccess: Bool
    let progress: ((Double) -> Void)?
    let dataReceived: (Data) -> Void
    let completion: (Error?) -> Void
  }

  var resolution: Result<LocalOriginalResource, OriginalExportFailure> = .success(
    LocalOriginalResource(
      identifier: "asset",
      originalFilename: "original.heic"
    )
  )
  var beforeReturningRequestId: ((PHAssetResourceDataRequestID) -> Void)?
  private(set) var requests: [Request] = []
  private(set) var cancelledIds: [PHAssetResourceDataRequestID] = []
  private let lock = NSLock()
  private let callbackQueue = DispatchQueue(label: "test.original-export-photo-kit")
  private var activeCallbacks = 0
  private(set) var peakActiveCallbacks = 0

  func resolveResource(
    assetId: String
  ) -> Result<LocalOriginalResource, OriginalExportFailure> {
    resolution
  }

  func requestData(
    for resource: LocalOriginalResource,
    allowsNetworkAccess: Bool,
    progress: ((Double) -> Void)?,
    dataReceived: @escaping (Data) -> Void,
    completion: @escaping (Error?) -> Void
  ) -> PHAssetResourceDataRequestID {
    lock.lock()
    XCTAssertFalse(Thread.isMainThread)
    let id = PHAssetResourceDataRequestID(requests.count + 1)
    requests.append(
      Request(
        id: id,
        allowsNetworkAccess: allowsNetworkAccess,
        progress: progress,
        dataReceived: dataReceived,
        completion: completion
      )
    )
    lock.unlock()
    beforeReturningRequestId?(id)
    return id
  }

  func cancel(_ requestId: PHAssetResourceDataRequestID) {
    lock.lock()
    cancelledIds.append(requestId)
    lock.unlock()
  }

  func send(_ data: Data, at index: Int) {
    let completed = DispatchSemaphore(value: 0)
    callbackQueue.async { [self] in
      defer { completed.signal() }
      XCTAssertFalse(Thread.isMainThread)
      lock.lock()
      activeCallbacks += 1
      peakActiveCallbacks = max(peakActiveCallbacks, activeCallbacks)
      lock.unlock()
      requests[index].dataReceived(data)
      lock.lock()
      activeCallbacks -= 1
      lock.unlock()
    }
    completed.wait()
  }
  func reportProgress(_ fraction: Double, at index: Int) { requests[index].progress?(fraction) }
  func complete(with error: Error? = nil, at index: Int) { requests[index].completion(error) }

  func waitUntilStarted(count: Int) {
    let deadline = Date().addingTimeInterval(1)
    while requestCount < count, RunLoop.current.run(mode: .default, before: deadline),
      Date() < deadline
    {}
    XCTAssertEqual(requestCount, count)
  }

  private var requestCount: Int {
    lock.lock()
    defer { lock.unlock() }
    return requests.count
  }
}

private final class RecordingOriginalExportFileStore: OriginalExportFileStoring {
  init(root: URL) {
    self.store = TemporaryOriginalExportFileStore(temporaryDirectory: root)
  }

  private let store: TemporaryOriginalExportFileStore
  private(set) var destinations: [OriginalExportDestination] = []
  private(set) var removeCount = 0
  var onCreate: (() -> Void)?
  var beforeAppend: (() -> Void)?
  var appendFailure: OriginalExportFailure?

  func createDestination(suggestedName: String) throws -> OriginalExportDestination {
    XCTAssertFalse(Thread.isMainThread)
    let destination = try store.createDestination(suggestedName: suggestedName)
    destinations.append(destination)
    onCreate?()
    return destination
  }

  func openPart(
    at destination: OriginalExportDestination
  ) throws -> any OriginalExportFileWriting {
    XCTAssertFalse(Thread.isMainThread)
    return ThreadCheckingOriginalExportFile(
      file: try store.openPart(at: destination),
      beforeWrite: { [weak self] in self?.beforeAppend?() },
      writeFailure: { [weak self] in self?.appendFailure }
    )
  }

  func commit(_ destination: OriginalExportDestination) throws -> URL {
    XCTAssertFalse(Thread.isMainThread)
    return try store.commit(destination)
  }

  func remove(_ destination: OriginalExportDestination) throws {
    XCTAssertFalse(Thread.isMainThread)
    removeCount += 1
    try store.remove(destination)
  }
}

private final class ThreadCheckingOriginalExportFile: OriginalExportFileWriting {
  init(
    file: any OriginalExportFileWriting,
    beforeWrite: @escaping () -> Void,
    writeFailure: @escaping () -> OriginalExportFailure?
  ) {
    self.file = file
    self.beforeWrite = beforeWrite
    self.writeFailure = writeFailure
  }

  private let file: any OriginalExportFileWriting
  private let beforeWrite: () -> Void
  private let writeFailure: () -> OriginalExportFailure?

  func write(contentsOf data: Data) throws {
    XCTAssertFalse(Thread.isMainThread)
    beforeWrite()
    if let failure = writeFailure() { throw failure }
    try file.write(contentsOf: data)
  }

  func close() throws {
    XCTAssertFalse(Thread.isMainThread)
    try file.close()
  }
}

private final class ManualOriginalExportTimeoutScheduler: OriginalExportTimeoutScheduling {
  private final class Task: OriginalExportScheduledTask {
    var cancelled = false
    func cancel() { cancelled = true }
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
    for (task, action) in pending where !task.cancelled { action() }
  }
}
