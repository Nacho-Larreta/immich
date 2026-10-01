import XCTest
#if canImport(background_downloader)
import background_downloader
#endif

final class BackupTaskEngineGateTests: XCTestCase {
  func testLateQueuedUploadCannotStartAfterEngineRetirement() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let gate = BackupTaskEngineGate(registry: registry)
    let metadata = "{\"operationIncarnation\":\"\(worker)\"}"
    let scheduledCall = try XCTUnwrap(registry.beginAdmission(for: worker))
    registry.fence(worker)
    registry.didDestroy(worker)

    XCTAssertNil(gate.begin(group: "backup_group", metadata: metadata))
    XCTAssertEqual(registry.state(of: worker), .unknown)
    scheduledCall.finish()
    XCTAssertEqual(registry.state(of: worker), .retired)
  }

  func testAlreadyRunningNativeAdmissionPreventsPrematureRecovery() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let gate = BackupTaskEngineGate(registry: registry)
    let admission = try XCTUnwrap(gate.begin(
      group: "backup_group", metadata: "{\"operationIncarnation\":\"\(worker)\"}"
    ))
    registry.fence(worker)
    registry.didDestroy(worker)

    XCTAssertEqual(registry.state(of: worker), .unknown)
    admission.finish()
    XCTAssertEqual(registry.state(of: worker), .retired)
  }

  func testNativeBypassCannotReadmitLegacyOrRetiredOwnedTask() {
    let registry = BackupEngineLifetimeRegistry()
    let gate = BackupTaskEngineGate(registry: registry)
    let worker = registry.register()
    registry.fence(worker)
    registry.didDestroy(worker)

    for group in ["backup_group", "backup_live_photo_group"] {
      for metadata in ["{}", "{\"operationIncarnation\":\"pid:123\"}",
                       "{\"operationIncarnation\":\"\(worker)\"}", "invalid"] {
        XCTAssertNil(gate.begin(group: group, metadata: metadata))
      }
    }
  }

  func testCallerCannotSubmitAnotherLiveEnginesIdentity() {
    let registry = BackupEngineLifetimeRegistry()
    let foreground = registry.register()
    let worker = registry.register()
    let gate = BackupTaskEngineGate(registry: registry)
    let metadata = "{\"operationIncarnation\":\"\(foreground)\"}"

    XCTAssertFalse(gate.acceptsOrigin(worker, group: "backup_group", metadata: metadata))
    XCTAssertTrue(gate.acceptsOrigin(foreground, group: "backup_group", metadata: metadata))
  }

  func testUnownedDownloadsKeepTheirExistingAdmissionPolicy() {
    let gate = BackupTaskEngineGate(registry: BackupEngineLifetimeRegistry())

    XCTAssertNotNil(gate.begin(group: "downloads", metadata: ""))
    XCTAssertTrue(gate.acceptsOrigin(nil, group: "downloads", metadata: ""))
  }

  func testAlreadyAcceptedHeldUploadContinuesAfterNormalWorkerDestruction() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let gate = BackupTaskEngineGate(registry: registry)
    let metadata = "{\"operationIncarnation\":\"\(worker)\"}"
    let accepted = try XCTUnwrap(gate.begin(taskId: "accepted", group: "backup_group", metadata: metadata))
    registry.fence(worker)
    registry.didDestroy(worker)

    XCTAssertNil(gate.begin(taskId: "new", group: "backup_group", metadata: metadata))
    XCTAssertEqual(registry.state(of: worker), .unknown)
    XCTAssertTrue(accepted.start(taskId: "accepted", group: "backup_group", metadata: metadata))
    XCTAssertEqual(registry.state(of: worker), .unknown)
    accepted.finish()
    XCTAssertEqual(registry.state(of: worker), .retired)
  }

  func testHeldUploadCancellationReleasesOnceAndCannotRestart() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let gate = BackupTaskEngineGate(registry: registry)
    let metadata = "{\"operationIncarnation\":\"\(worker)\"}"
    let accepted = try XCTUnwrap(gate.begin(taskId: "accepted", group: "backup_group", metadata: metadata))
    registry.fence(worker)
    registry.didDestroy(worker)
    accepted.finish()
    accepted.finish()

    XCTAssertFalse(accepted.start(taskId: "accepted", group: "backup_group", metadata: metadata))
    XCTAssertEqual(registry.state(of: worker), .retired)
  }

  func testAdmissionCannotBeReusedForAnotherTaskOrTwice() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let gate = BackupTaskEngineGate(registry: registry)
    let metadata = "{\"operationIncarnation\":\"\(worker)\"}"
    let accepted = try XCTUnwrap(gate.begin(taskId: "accepted", group: "backup_group", metadata: metadata))

    XCTAssertFalse(accepted.start(taskId: "replacement", group: "backup_group", metadata: metadata))
    XCTAssertTrue(accepted.start(taskId: "accepted", group: "backup_group", metadata: metadata))
    XCTAssertFalse(accepted.start(taskId: "accepted", group: "backup_group", metadata: metadata))
    accepted.finish()
  }
}
