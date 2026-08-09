import Foundation
import XCTest

@testable import Runner

final class OriginalExportLeaseRegistryTests: XCTestCase {
  func testJanitorRemovesOnlyExpiredOwnedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let expiredOwned = root.appendingPathComponent("immich-share-expired", isDirectory: true)
    let recentOwned = root.appendingPathComponent("immich-share-recent", isDirectory: true)
    let unrelated = root.appendingPathComponent("other-expired", isDirectory: true)
    for directory in [expiredOwned, recentOwned, unrelated] {
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    }
    let oldDate = Date(
      timeIntervalSinceNow: -TemporaryOriginalExportFileStore.staleLeaseAge * 2
    )
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate],
      ofItemAtPath: expiredOwned.path
    )
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate],
      ofItemAtPath: unrelated.path
    )
    let performance = RecordingPerformanceRecorder()
    let store = TemporaryOriginalExportFileStore(
      temporaryDirectory: root,
      performanceRecorder: performance
    )
    let cleaned = expectation(description: "janitor completed off main")

    DispatchQueue.global(qos: .utility).async {
      do {
        try store.cleanupExpiredOwnedDirectories(olderThan: Date().addingTimeInterval(-60))
      } catch {
        XCTFail("Janitor failed: \(error)")
      }
      cleaned.fulfill()
    }
    wait(for: [cleaned], timeout: 1)

    XCTAssertFalse(FileManager.default.fileExists(atPath: expiredOwned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: recentOwned.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertEqual(performance.startedCount(.temporary), 1)
    XCTAssertEqual(performance.finishedCount(.temporary), 1)
  }

  func testReleaseDeletesRegisteredLeaseOnceAndRejectsUnknownTokensWithoutUsingThemAsPaths()
    throws
  {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let unrelated = root.appendingPathComponent("must-survive.txt")
    try Data("unrelated".utf8).write(to: unrelated)
    let executor = SerialOriginalExportIOExecutor()
    let registry = OriginalExportLeaseRegistry(ioExecutor: executor)
    let store = LeaseRegistryRecordingStore(root: root)
    let writer = try makeCommittedWriter(store: store)
    let committed = try XCTUnwrap(store.destination?.committed)
    let token = try registry.adopt(writer: writer, committedURL: committed)

    XCTAssertNotEqual(token, committed.path)
    XCTAssertEqual(registry.registeredPath(for: token), committed.standardizedFileURL)

    let released = expectation(description: "all concurrent release waiters complete")
    released.expectedFulfillmentCount = 2
    registry.release(token: token) { result in
      XCTAssertNil(result.error)
      released.fulfill()
    }
    registry.release(token: token) { result in
      XCTAssertNil(result.error)
      released.fulfill()
    }
    wait(for: [released], timeout: 1)

    XCTAssertEqual(store.removeCount, 1)
    XCTAssertFalse(FileManager.default.fileExists(atPath: committed.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))

    let repeated = expectation(description: "released token becomes unknown")
    registry.release(token: token) { result in
      XCTAssertEqual(result.error, .leaseNotFound)
      repeated.fulfill()
    }
    let arbitraryPath = expectation(description: "arbitrary path is not a lease token")
    registry.release(token: unrelated.path) { result in
      XCTAssertEqual(result.error, .leaseNotFound)
      arbitraryPath.fulfill()
    }
    wait(for: [repeated, arbitraryPath], timeout: 1)
    XCTAssertEqual(store.removeCount, 1)
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
  }

  func testCleanupFailureKeepsLeaseAndTemporarySpanOpenUntilRetrySucceeds() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let executor = SerialOriginalExportIOExecutor()
    let registry = OriginalExportLeaseRegistry(ioExecutor: executor)
    let store = LeaseRegistryRecordingStore(root: root)
    let performance = RecordingPerformanceRecorder()
    let writer = try makeCommittedWriter(store: store, performanceRecorder: performance)
    let committed = try XCTUnwrap(store.destination?.committed)
    let token = try registry.adopt(writer: writer, committedURL: committed)
    store.removeFailuresRemaining = 1

    let failed = expectation(description: "first release reports cleanup failure")
    registry.release(token: token) { result in
      XCTAssertEqual(result.error, .cleanupFailed)
      failed.fulfill()
    }
    wait(for: [failed], timeout: 1)

    XCTAssertEqual(registry.registeredPath(for: token), committed.standardizedFileURL)
    XCTAssertEqual(performance.activeCount(.temporary), 1)
    XCTAssertEqual(performance.finishedCount(.temporary), 0)

    let retried = expectation(description: "retry removes lease")
    registry.release(token: token) { result in
      XCTAssertNil(result.error)
      retried.fulfill()
    }
    wait(for: [retried], timeout: 1)

    XCTAssertNil(registry.registeredPath(for: token))
    XCTAssertEqual(store.removeCount, 2)
    XCTAssertEqual(performance.activeCount(.temporary), 0)
    XCTAssertEqual(performance.finishedCount(.temporary), 1)
  }

  private func makeCommittedWriter(
    store: LeaseRegistryRecordingStore,
    performanceRecorder: any PerformanceRecording = PerformanceTelemetry.shared
  ) throws -> OriginalExportLeaseWriter {
    let destination = try store.createDestination(suggestedName: "asset.jpg")
    let writer = OriginalExportLeaseWriter(
      destination: destination,
      store: store,
      performanceRecorder: performanceRecorder
    )
    try writer.open()
    try writer.append(Data("original".utf8))
    _ = try writer.commit()
    return writer
  }
}

private final class LeaseRegistryRecordingStore: OriginalExportFileStoring {
  init(root: URL) {
    store = TemporaryOriginalExportFileStore(temporaryDirectory: root)
  }

  private let store: TemporaryOriginalExportFileStore
  private(set) var destination: OriginalExportDestination?
  private(set) var removeCount = 0
  var removeFailuresRemaining = 0

  func createDestination(suggestedName: String) throws -> OriginalExportDestination {
    let destination = try store.createDestination(suggestedName: suggestedName)
    self.destination = destination
    return destination
  }

  func openPart(
    at destination: OriginalExportDestination
  ) throws -> any OriginalExportFileWriting {
    try store.openPart(at: destination)
  }

  func commit(_ destination: OriginalExportDestination) throws -> URL {
    try store.commit(destination)
  }

  func remove(_ destination: OriginalExportDestination) throws {
    XCTAssertFalse(Thread.isMainThread)
    removeCount += 1
    if removeFailuresRemaining > 0 {
      removeFailuresRemaining -= 1
      throw OriginalExportFailure.cleanupFailed
    }
    try store.remove(destination)
  }
}
