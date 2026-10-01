import XCTest
@testable import background_downloader
@testable import Runner

@MainActor
final class ManualUploadRequestContextTests: XCTestCase {
  private var file: URL!
  private var session: URLSession!
  private var originalSession: URLSession?
  private var identity: String!

  override func setUpWithError() throws {
    file = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
    try Data("manual-upload-fixture".utf8).write(to: file)
    originalSession = UrlSessionDelegate.urlSession
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ManualUploadRequestURLProtocol.self]
    session = URLSession(configuration: configuration)
    UrlSessionDelegate.urlSession = session
    identity = BackupEngineLifetimeRegistry.shared.register()
    try commitContext(token: "fixture-current")
    URLSessionManager.patchBackgroundDownloader()
  }

  override func tearDownWithError() throws {
    session.invalidateAndCancel()
    UrlSessionDelegate.urlSession = originalSession
    ManualUploadRequestURLProtocol.onRequest = nil
    BackupEngineLifetimeRegistry.shared.fence(identity)
    BackupEngineLifetimeRegistry.shared.didDestroy(identity)
    try URLSessionManager.replaceRequestContext(headers: [:], canonicalOrigin: nil, token: nil)
    BackgroundDownloaderRequestContextBridge.reset()
    try FileManager.default.removeItem(at: file)
  }

  func testManualTaskPersistsNoCredentialsAndUsesAuthorizedContextAtNativeAdmission() async throws {
    let revision = try currentRevision()
    let task = makeTask(revision: revision)
    let encoded = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
    XCTAssertTrue(task.headers.isEmpty)
    XCTAssertFalse(encoded.contains("fixture-current"))
    let received = expectation(description: "manual upload uses authorized native context")
    ManualUploadRequestURLProtocol.onRequest = { request in
      XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer fixture-current")
      received.fulfill()
    }

    let accepted = await BDPlugin.instance.doEnqueue(taskJsonString: encoded, notificationConfigJsonString: nil, resumeDataAsBase64String: "")

    XCTAssertTrue(accepted)
    await fulfillment(of: [received], timeout: 2)
    let nativeTasks = await session.allTasks
    XCTAssertEqual(nativeTasks.count, 1)
    XCTAssertFalse(nativeTasks.first?.taskDescription?.contains("fixture-current") ?? true)
  }

  func testAccountRevisionReplacementRejectsOldManualAttemptBeforeCreatingNativeTask() async throws {
    let task = makeTask(revision: try currentRevision())
    let encoded = String(decoding: try JSONEncoder().encode(task), as: UTF8.self)
    try commitContext(token: "fixture-replacement")

    let accepted = await BDPlugin.instance.doEnqueue(taskJsonString: encoded, notificationConfigJsonString: nil, resumeDataAsBase64String: "")

    XCTAssertFalse(accepted)
    let nativeTasks = await session.allTasks
    XCTAssertTrue(nativeTasks.isEmpty)
    XCTAssertFalse(encoded.contains("fixture-current"))
    XCTAssertFalse(encoded.contains("fixture-replacement"))
  }

  private func commitContext(token: String) throws {
    try URLSessionManager.replaceRequestContext(
      headers: ["Authorization": "Bearer \(token)"], canonicalOrigin: "https://manual-upload.test", token: token
    )
  }

  private func currentRevision() throws -> UInt64 {
    let url = try XCTUnwrap(URL(string: "https://manual-upload.test/api/assets"))
    return try XCTUnwrap(BackgroundDownloaderRequestContextBridge.prepare(URLRequest(url: url))).context.revision
  }

  private func makeTask(revision: UInt64) -> background_downloader.Task {
    background_downloader.Task(
      taskId: UUID().uuidString,
      url: "https://manual-upload.test/api/assets",
      filename: file.lastPathComponent,
      httpRequestMethod: "POST",
      post: "binary",
      directory: file.deletingLastPathComponent().path,
      baseDirectory: BaseDirectory.root.rawValue,
      group: "manual_upload_group",
      updates: Updates.none.rawValue,
      metaData: "{\"bindingDigest\":\"fixture-binding\",\"operationIncarnation\":\"\(identity!)\",\"expectedNativeRevision\":\(revision)}",
      taskType: "UploadTask"
    )
  }
}

private final class ManualUploadRequestURLProtocol: URLProtocol {
  static var onRequest: ((URLRequest) -> Void)?

  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() { Self.onRequest?(request) }
  override func stopLoading() {}
}
