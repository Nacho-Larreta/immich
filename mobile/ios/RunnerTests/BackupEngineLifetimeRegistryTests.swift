import XCTest
#if canImport(background_downloader)
import background_downloader
#endif

final class BackupEngineLifetimeRegistryTests: XCTestCase {
  func testDestroyedWorkerRetiresWhileSiblingInSameProcessStaysAlive() {
    let registry = BackupEngineLifetimeRegistry()
    let foreground = registry.register()
    let worker = registry.register()

    registry.fence(worker)
    registry.didDestroy(worker)

    XCTAssertNotEqual(foreground, worker)
    XCTAssertEqual(registry.state(of: worker), .retired)
    XCTAssertEqual(registry.state(of: foreground), .alive)
    XCTAssertNil(registry.beginAdmission(for: worker))
    XCTAssertNotNil(registry.beginAdmission(for: foreground))
  }

  func testDestroyedEngineCannotRetireBeforeAlreadyDispatchedAdmissionFinishes() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let admission = try XCTUnwrap(registry.beginAdmission(for: worker))

    registry.fence(worker)
    registry.didDestroy(worker)

    XCTAssertEqual(registry.state(of: worker), .unknown)
    XCTAssertNil(registry.beginAdmission(for: worker))
    admission.finish()
    XCTAssertEqual(registry.state(of: worker), .retired)
    admission.finish()
    XCTAssertEqual(registry.state(of: worker), .retired)
  }

  func testQuarantinedOrFencedButNotDestroyedEngineIsNotRetired() {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()

    XCTAssertEqual(registry.state(of: worker), .alive)
    registry.fence(worker)

    XCTAssertEqual(registry.state(of: worker), .alive)
    XCTAssertNil(registry.beginAdmission(for: worker))
  }

  func testDifferentProcessGenerationRetiresEvenIfOperatingSystemReusesPid() {
    let oldProcess = BackupEngineLifetimeRegistry()
    let oldWorker = oldProcess.register()
    let newProcess = BackupEngineLifetimeRegistry()
    let foreground = newProcess.register()

    XCTAssertEqual(newProcess.state(of: oldWorker), .retired)
    XCTAssertEqual(newProcess.state(of: foreground), .alive)
    XCTAssertNil(newProcess.beginAdmission(for: oldWorker))
  }

  func testUnknownIdentityCannotBecomeDeathProof() {
    let registry = BackupEngineLifetimeRegistry()
    let known = registry.register()
    let pieces = known.split(separator: ":")
    let unregistered = "\(pieces[0]):\(pieces[1]):9999"

    for identity in ["", "pid:invalid", "ios-engine-v1:unknown:1", unregistered] {
      XCTAssertEqual(registry.state(of: identity), .unknown)
      XCTAssertNil(registry.beginAdmission(for: identity))
    }
  }

  func testColdNewBinaryRetiresLegacyPidButNeverAdmitsLegacyTask() {
    let registry = BackupEngineLifetimeRegistry()

    XCTAssertEqual(registry.state(of: "pid:123"), .retired)
    XCTAssertNil(registry.beginAdmission(for: "pid:123"))
  }

  func testDestructionWithoutAdmissionFenceDoesNotProveRetirement() {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()

    registry.didDestroy(worker)

    XCTAssertEqual(registry.state(of: worker), .alive)
  }

  func testMultipleInFlightAdmissionsMustAllFinish() throws {
    let registry = BackupEngineLifetimeRegistry()
    let worker = registry.register()
    let first = try XCTUnwrap(registry.beginAdmission(for: worker))
    let second = try XCTUnwrap(registry.beginAdmission(for: worker))
    registry.fence(worker)
    registry.didDestroy(worker)

    first.finish()
    XCTAssertEqual(registry.state(of: worker), .unknown)
    second.finish()
    XCTAssertEqual(registry.state(of: worker), .retired)
  }
}
