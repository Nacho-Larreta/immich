import Flutter
import XCTest
import background_downloader

@MainActor
final class BackupEngineRegistrationTests: XCTestCase {
  func testWorkerRegistrationPreservesPrimaryCallbacksAndPublishesDistinctIdentity() throws {
    let originalBackground = BDPlugin.backgroundChannel
    let originalCallback = BDPlugin.callbackChannel
    BDPlugin.backgroundChannel = nil
    BDPlugin.callbackChannel = nil
    defer {
      BDPlugin.backgroundChannel = originalBackground
      BDPlugin.callbackChannel = originalCallback
    }
    let foreground = FlutterEngine(name: "lifetime-test-foreground")
    let worker = FlutterEngine(name: "lifetime-test-worker")
    XCTAssertTrue(foreground.run())
    XCTAssertTrue(worker.run())
    let foregroundRegistrar = try XCTUnwrap(foreground.registrar(forPlugin: "BackgroundDownloaderPlugin"))
    BackgroundDownloaderPlugin.register(with: foregroundRegistrar)
    let primaryBackground = try XCTUnwrap(BDPlugin.backgroundChannel)
    let primaryCallback = try XCTUnwrap(BDPlugin.callbackChannel)
    let foregroundDelegate = try XCTUnwrap(
      foreground.valuePublished(byPlugin: "BackgroundDownloaderPlugin") as? BackupEngineMethodDelegate
    )
    let workerRegistrar = try XCTUnwrap(worker.registrar(forPlugin: "BackgroundDownloaderPlugin"))
    BackgroundDownloaderPlugin.register(with: workerRegistrar)
    let workerDelegate = try XCTUnwrap(
      worker.valuePublished(byPlugin: "BackgroundDownloaderPlugin") as? BackupEngineMethodDelegate
    )

    XCTAssertTrue(primaryBackground === BDPlugin.backgroundChannel)
    XCTAssertTrue(primaryCallback === BDPlugin.callbackChannel)
    XCTAssertNotEqual(foregroundDelegate.operationIdentity, workerDelegate.operationIdentity)
    XCTAssertEqual(BackupEngineLifetimeRegistry.shared.state(of: workerDelegate.operationIdentity), .alive)
    workerDelegate.fenceAdmissions()
    worker.destroyContext()
    workerDelegate.engineWasDestroyed()

    XCTAssertEqual(BackupEngineLifetimeRegistry.shared.state(of: workerDelegate.operationIdentity), .retired)
    XCTAssertEqual(BackupEngineLifetimeRegistry.shared.state(of: foregroundDelegate.operationIdentity), .alive)
    XCTAssertTrue(primaryBackground === BDPlugin.backgroundChannel)
    XCTAssertTrue(primaryCallback === BDPlugin.callbackChannel)
    foregroundDelegate.fenceAdmissions()
    foreground.destroyContext()
    foregroundDelegate.engineWasDestroyed()
  }

  func testQueuedMethodRetainsAdmissionUntilDetachedBatchHasReplied() async {
    let registry = BackupEngineLifetimeRegistry()
    let delegate = BackupEngineMethodDelegate(registry: registry)
    let replied = expectation(description: "dispatched batch replied")
    delegate.handle(FlutterMethodCall(methodName: "enqueueAll", arguments: ["[]", "[]"])) { _ in
      replied.fulfill()
    }
    delegate.fenceAdmissions()
    delegate.engineWasDestroyed()

    XCTAssertEqual(registry.state(of: delegate.operationIdentity), .unknown)
    await fulfillment(of: [replied], timeout: 2)
    XCTAssertEqual(registry.state(of: delegate.operationIdentity), .retired)
  }

  func testLateMethodIsRejectedWithoutStartingNativeDispatch() {
    let registry = BackupEngineLifetimeRegistry()
    let delegate = BackupEngineMethodDelegate(registry: registry)
    delegate.fenceAdmissions()
    delegate.engineWasDestroyed()
    var response: Any?

    delegate.handle(FlutterMethodCall(methodName: "enqueueAll", arguments: ["[]", "[]"])) {
      response = $0
    }

    XCTAssertEqual((response as? FlutterError)?.code, "backup-engine-retired")
    XCTAssertEqual(registry.state(of: delegate.operationIdentity), .retired)
  }
}
