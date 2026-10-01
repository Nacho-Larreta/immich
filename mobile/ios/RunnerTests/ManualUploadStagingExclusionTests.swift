import Foundation
import XCTest
@testable import background_downloader

final class ManualUploadStagingExclusionTests: XCTestCase {
  private var applicationSupport: URL!

  override func setUpWithError() throws {
    applicationSupport = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: applicationSupport, withIntermediateDirectories: true)
  }

  override func tearDownWithError() throws {
    try FileManager.default.removeItem(at: applicationSupport)
  }

  func testOnlyOwnedRootIsCreatedAndExcludedFromCloudBackup() throws {
    let root = applicationSupport.appendingPathComponent("manual-upload-staging-v1")
    let exclusion = ManualUploadStagingExclusion(applicationSupport: applicationSupport)

    XCTAssertTrue(try exclusion.prepare(absoluteRoot: root.path))
    XCTAssertTrue(try root.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup == true)
    XCTAssertTrue(try exclusion.prepare(absoluteRoot: root.path))
  }

  func testAnotherDirectoryCannotBeModified() throws {
    let sibling = applicationSupport.appendingPathComponent("borrowed")
    let exclusion = ManualUploadStagingExclusion(applicationSupport: applicationSupport)

    XCTAssertThrowsError(try exclusion.prepare(absoluteRoot: sibling.path))
    XCTAssertFalse(FileManager.default.fileExists(atPath: sibling.path))
    XCTAssertThrowsError(try exclusion.prepare(absoluteRoot: "manual-upload-staging-v1"))
  }

  func testSymbolicLinkCannotRedirectOwnedRoot() throws {
    let borrowed = applicationSupport.appendingPathComponent("borrowed")
    let root = applicationSupport.appendingPathComponent("manual-upload-staging-v1")
    try FileManager.default.createDirectory(at: borrowed, withIntermediateDirectories: false)
    try FileManager.default.createSymbolicLink(at: root, withDestinationURL: borrowed)
    let exclusion = ManualUploadStagingExclusion(applicationSupport: applicationSupport)

    XCTAssertThrowsError(try exclusion.prepare(absoluteRoot: root.path))
    XCTAssertNotEqual(try borrowed.resourceValues(forKeys: [.isExcludedFromBackupKey]).isExcludedFromBackup, true)
  }

  func testExistingFileCannotBeReplacedWithDirectory() throws {
    let root = applicationSupport.appendingPathComponent("manual-upload-staging-v1")
    let marker = Data("preserve-existing-file".utf8)
    try marker.write(to: root)
    let exclusion = ManualUploadStagingExclusion(applicationSupport: applicationSupport)

    XCTAssertThrowsError(try exclusion.prepare(absoluteRoot: root.path))
    XCTAssertEqual(try Data(contentsOf: root), marker)
  }
}
