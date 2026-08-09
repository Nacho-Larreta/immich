import XCTest

@testable import Runner

final class ConnectivityApiImplTests: XCTestCase {
  func testInitialSnapshotIsUnknownBeforeTheMonitorPublishes() throws {
    let harness = Harness()

    XCTAssertEqual(try harness.api.getSnapshot().availability, .unknown)
    XCTAssertEqual(try harness.api.getSnapshot().capabilities, [])
  }

  func testSatisfiedPathIsAvailableAndPreservesCapabilities() throws {
    let harness = Harness()
    try harness.api.start()

    harness.monitors[0].emit(
      path(
        status: .satisfied,
        usesCellular: true,
        usesWifi: true,
        usesOther: true,
        isExpensive: false,
        isConstrained: false
      )
    )

    XCTAssertEqual(try harness.api.getSnapshot().availability, .available)
    XCTAssertEqual(
      try harness.api.getSnapshot().capabilities,
      [.cellular, .wifi, .vpn]
    )
    XCTAssertEqual(harness.flutter.snapshots.last?.availability, .available)
  }

  func testUnsatisfiedPathIsUnavailable() throws {
    let harness = Harness()
    try harness.api.start()

    harness.monitors[0].emit(path(status: .unsatisfied))

    XCTAssertEqual(try harness.api.getSnapshot().availability, .unavailable)
    XCTAssertEqual(try harness.api.getSnapshot().capabilities, [])
    XCTAssertEqual(harness.flutter.snapshots.last?.availability, .unavailable)
  }

  func testRequiresConnectionAndUnknownPathsRemainUnknown() throws {
    for status in [ConnectivityPathStatus.requiresConnection, .unknown] {
      let harness = Harness()
      try harness.api.start()

      harness.monitors[0].emit(path(status: status, usesWifi: true))

      XCTAssertEqual(try harness.api.getSnapshot().availability, .unknown)
      XCTAssertEqual(try harness.api.getSnapshot().capabilities, [])
      XCTAssertEqual(harness.flutter.snapshots.last?.availability, .unknown)
    }
  }

  func testSynchronousStartCallbackDoesNotDeadlock() throws {
    let harness = Harness(pathOnStart: path(status: .satisfied, usesWifi: true))

    try harness.api.start()

    XCTAssertEqual(try harness.api.getSnapshot().availability, .available)
  }

  func testStaleMonitorRevisionCannotPublishAfterRestart() throws {
    let harness = Harness()
    try harness.api.start()
    let staleMonitor = harness.monitors[0]
    try harness.api.stop()
    try harness.api.start()

    staleMonitor.emit(path(status: .satisfied, usesWifi: true))

    XCTAssertEqual(try harness.api.getSnapshot().availability, .unknown)
    XCTAssertTrue(harness.flutter.snapshots.isEmpty)

    harness.monitors[1].emit(path(status: .unsatisfied))
    XCTAssertEqual(try harness.api.getSnapshot().availability, .unavailable)
    XCTAssertEqual(harness.flutter.snapshots.map(\.availability), [.unavailable])
  }

  func testStartStopAndDisposeAreIdempotent() throws {
    let harness = Harness()

    try harness.api.start()
    try harness.api.start()
    XCTAssertEqual(harness.monitors.count, 1)
    XCTAssertEqual(harness.monitors[0].startCount, 1)

    try harness.api.stop()
    try harness.api.stop()
    XCTAssertEqual(harness.monitors[0].cancelCount, 1)

    try harness.api.start()
    XCTAssertEqual(harness.monitors.count, 2)
    try harness.api.dispose()
    try harness.api.dispose()
    XCTAssertEqual(harness.monitors[1].cancelCount, 1)
  }

  private func path(
    status: ConnectivityPathStatus,
    usesCellular: Bool = false,
    usesWifi: Bool = false,
    usesOther: Bool = false,
    isExpensive: Bool = false,
    isConstrained: Bool = false
  ) -> ConnectivityPathValue {
    ConnectivityPathValue(
      status: status,
      usesCellular: usesCellular,
      usesWifi: usesWifi,
      usesOther: usesOther,
      isExpensive: isExpensive,
      isConstrained: isConstrained
    )
  }
}

private final class Harness {
  let flutter = FlutterApiSpy()
  private(set) var monitors: [PathMonitorSpy] = []
  private let pathOnStart: ConnectivityPathValue?

  init(pathOnStart: ConnectivityPathValue? = nil) {
    self.pathOnStart = pathOnStart
  }

  lazy var api = ConnectivityApiImpl(
    flutterApi: flutter,
    monitorFactory: {
      let monitor = PathMonitorSpy()
      monitor.pathToEmitOnStart = self.pathOnStart
      self.monitors.append(monitor)
      return monitor
    }
  )
}

private final class FlutterApiSpy: ConnectivityFlutterApiProtocol {
  private(set) var snapshots: [ConnectivityTransportSnapshot] = []

  func onTransportChanged(
    snapshot: ConnectivityTransportSnapshot,
    completion: @escaping (Result<Void, PigeonError>) -> Void
  ) {
    snapshots.append(snapshot)
    completion(.success(()))
  }
}

private final class PathMonitorSpy: ConnectivityPathMonitoring {
  var pathUpdateHandler: ((ConnectivityPathValue) -> Void)?
  var pathToEmitOnStart: ConnectivityPathValue?
  private(set) var startCount = 0
  private(set) var cancelCount = 0

  func start(queue: DispatchQueue) {
    startCount += 1
    if let pathToEmitOnStart {
      emit(pathToEmitOnStart)
    }
  }

  func cancel() {
    cancelCount += 1
  }

  func emit(_ path: ConnectivityPathValue) {
    pathUpdateHandler?(path)
  }
}
