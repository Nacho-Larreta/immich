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
    let store = TemporaryOriginalExportFileStore(temporaryDirectory: root)
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

  private func makeCommittedWriter(
    store: LeaseRegistryRecordingStore
  ) throws -> OriginalExportLeaseWriter {
    let destination = try store.createDestination(suggestedName: "asset.jpg")
    let writer = OriginalExportLeaseWriter(destination: destination, store: store)
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
    try store.remove(destination)
  }
}
