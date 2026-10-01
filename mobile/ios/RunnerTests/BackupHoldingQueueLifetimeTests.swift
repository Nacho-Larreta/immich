import Flutter
import XCTest
@testable import background_downloader

@MainActor
final class BackupHoldingQueueLifetimeTests: XCTestCase {
  func testAcceptedHeldTaskRemainsVisibleAfterWorkerDestructionAndReleasesOnCancellation() async throws {
    let originalQueue = BDPlugin.holdingQueue
    defer { BDPlugin.holdingQueue = originalQueue }
    let worker = BackupEngineMethodDelegate()
    let task = makeTask(identity: worker.operationIdentity)
    let configured = expectation(description: "holding queue configured")
    worker.handle(FlutterMethodCall(methodName: "configHoldingQueue", arguments: [0, 1, 1])) { _ in
      configured.fulfill()
    }
    await fulfillment(of: [configured], timeout: 2)
    let queued = expectation(description: "owned task accepted")
    let tasks = try String(decoding: JSONEncoder().encode([task]), as: UTF8.self)
    worker.handle(FlutterMethodCall(methodName: "enqueueAll", arguments: [tasks, "[null]"])) { result in
      XCTAssertEqual(result as? [Bool], [true])
      queued.fulfill()
    }
    await fulfillment(of: [queued], timeout: 2)
    worker.fenceAdmissions()
    worker.engineWasDestroyed()

    let queue = try XCTUnwrap(BDPlugin.holdingQueue)
    await queue.stateLock.lock()
    XCTAssertEqual(queue.allTasks(group: "backup_group").map(\.taskId), [task.taskId])
    XCTAssertEqual(BackupEngineLifetimeRegistry.shared.state(of: worker.operationIdentity), .unknown)
    XCTAssertEqual(queue.cancelTasksWithIds([task.taskId]), [task.taskId])
    await queue.stateLock.unlock()

    XCTAssertEqual(BackupEngineLifetimeRegistry.shared.state(of: worker.operationIdentity), .retired)
  }

  func testAcceptedHeldUploadMaterializesAfterWorkerDestruction() async throws {
    let registry = BackupEngineLifetimeRegistry.shared
    let identity = registry.register()
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("owned-upload".utf8).write(to: file)
    defer { try? FileManager.default.removeItem(at: file) }
    let originalSession = UrlSessionDelegate.urlSession
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [HeldUploadURLProtocol.self]
    let session = URLSession(configuration: configuration)
    UrlSessionDelegate.urlSession = session
    BackgroundDownloaderRequestContextBridge.reset()
    defer {
      session.invalidateAndCancel()
      UrlSessionDelegate.urlSession = originalSession
      HeldUploadURLProtocol.onStart = nil
    }
    let started = expectation(description: "accepted upload reaches URLSession")
    HeldUploadURLProtocol.onStart = { started.fulfill() }
    let task = makeTask(identity: identity, file: file)
    let admission = try XCTUnwrap(BackupTaskEngineGate.shared.begin(
      taskId: task.taskId, group: task.group, metadata: task.metaData
    ))
    let item = EnqueueItem(task: task, notificationConfigJsonString: nil, resumeDataAsBase64String: "", nativeAdmission: admission)
    registry.fence(identity)
    registry.didDestroy(identity)

    await item.enqueue()
    await fulfillment(of: [started], timeout: 2)
    let nativeTasks = await session.allTasks

    XCTAssertEqual(nativeTasks.count, 1)
    XCTAssertEqual(nativeTasks.first?.state, .running)
    XCTAssertEqual(registry.state(of: identity), .retired)
    XCTAssertNil(BackupTaskEngineGate.shared.begin(taskId: "late-new", group: task.group, metadata: task.metaData))
  }

  private func makeTask(identity: String, file: URL? = nil) -> background_downloader.Task {
    background_downloader.Task(
      taskId: UUID().uuidString,
      url: "https://upload.test/assets",
      filename: file?.lastPathComponent ?? "unused.bin",
      httpRequestMethod: "POST",
      post: "binary",
      directory: file?.deletingLastPathComponent().path ?? "",
      baseDirectory: BaseDirectory.root.rawValue,
      group: "backup_group",
      updates: Updates.none.rawValue,
      metaData: "{\"operationIncarnation\":\"\(identity)\",\"expectedNativeRevision\":1}",
      taskType: "UploadTask"
    )
  }
}

private final class HeldUploadURLProtocol: URLProtocol {
  static var onStart: (() -> Void)?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.onStart?() }
  override func stopLoading() {}
}
