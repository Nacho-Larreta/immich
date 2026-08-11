import Foundation
import XCTest

@testable import Runner

final class OriginalExportLeaseRegistryTests: XCTestCase {
  func testJanitorRemovesOnlyExpiredOwnedDirectories() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let exportRoot = root.appendingPathComponent(
      TemporaryOriginalExportFileStore.ownedRootName,
      isDirectory: true
    )
    try FileManager.default.createDirectory(at: exportRoot, withIntermediateDirectories: false)
    let expiredOwned = exportRoot.appendingPathComponent(
      "immich-share-550E8400-E29B-41D4-A716-446655440000",
      isDirectory: true
    )
    let recentOwned = exportRoot.appendingPathComponent(
      "immich-share-550E8400-E29B-41D4-A716-446655440001",
      isDirectory: true
    )
    let invalidOwned = exportRoot.appendingPathComponent("immich-share-not-a-uuid", isDirectory: true)
    let unrelated = root.appendingPathComponent("other-expired", isDirectory: true)
    for directory in [expiredOwned, recentOwned, invalidOwned, unrelated] {
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
    try FileManager.default.setAttributes(
      [.modificationDate: oldDate],
      ofItemAtPath: invalidOwned.path
    )
    let ownedSymlink = exportRoot.appendingPathComponent(
      "immich-share-550E8400-E29B-41D4-A716-446655440002",
      isDirectory: true
    )
    try FileManager.default.createSymbolicLink(at: ownedSymlink, withDestinationURL: unrelated)
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
    XCTAssertTrue(FileManager.default.fileExists(atPath: invalidOwned.path))
    XCTAssertNoThrow(try FileManager.default.destinationOfSymbolicLink(atPath: ownedSymlink.path))
    XCTAssertTrue(FileManager.default.fileExists(atPath: unrelated.path))
    XCTAssertEqual(performance.startedCount(.temporary), 1)
    XCTAssertEqual(performance.finishedCount(.temporary), 1)
  }

  func testDestinationUsesDedicatedCacheRootAndExclusivePartCreation() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TemporaryOriginalExportFileStore(temporaryDirectory: root)

    let destination = try store.createDestination(suggestedName: "photo.jpg")

    XCTAssertEqual(
      destination.directory.deletingLastPathComponent().lastPathComponent,
      TemporaryOriginalExportFileStore.ownedRootName
    )
    let first = try store.openPart(at: destination)
    XCTAssertThrowsError(try store.openPart(at: destination))
    try first.close()
    try store.remove(destination)
  }

  func testStoreRejectsSymlinkedOwnedRoot() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    let outside = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
    defer {
      try? FileManager.default.removeItem(at: root)
      try? FileManager.default.removeItem(at: outside)
    }
    try FileManager.default.createSymbolicLink(
      at: root.appendingPathComponent(TemporaryOriginalExportFileStore.ownedRootName),
      withDestinationURL: outside
    )
    let store = TemporaryOriginalExportFileStore(temporaryDirectory: root)

    XCTAssertThrowsError(try store.createDestination(suggestedName: "photo.jpg"))
    XCTAssertTrue(FileManager.default.fileExists(atPath: outside.path))
  }

  func testDestinationCollisionNeverReusesOrOverwritesOwnedDirectory() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let fixedUUID = try XCTUnwrap(
      UUID(uuidString: "550E8400-E29B-41D4-A716-446655440005")
    )
    let store = TemporaryOriginalExportFileStore(
      temporaryDirectory: root,
      makeUUID: { fixedUUID }
    )

    let first = try store.createDestination(suggestedName: "photo.jpg")
    try Data("must-survive".utf8).write(to: first.committed)

    XCTAssertThrowsError(try store.createDestination(suggestedName: "replacement.jpg"))
    XCTAssertEqual(try Data(contentsOf: first.committed), Data("must-survive".utf8))
  }

  func testPartCreationRejectsPreplantedSymlinkWithoutTouchingTarget() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = TemporaryOriginalExportFileStore(temporaryDirectory: root)
    let destination = try store.createDestination(suggestedName: "photo.jpg")
    let target = root.appendingPathComponent("must-survive.txt")
    try Data("must-survive".utf8).write(to: target)
    try FileManager.default.createSymbolicLink(
      at: destination.part,
      withDestinationURL: target
    )

    XCTAssertThrowsError(try store.openPart(at: destination))
    XCTAssertEqual(try Data(contentsOf: target), Data("must-survive".utf8))
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
