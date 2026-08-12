import Foundation
import Network

enum ConnectivityPathStatus {
  case satisfied
  case unsatisfied
  case requiresConnection
  case unknown
}

struct ConnectivityPathValue {
  let status: ConnectivityPathStatus
  let usesCellular: Bool
  let usesWifi: Bool
  let usesOther: Bool
  let isExpensive: Bool
  let isConstrained: Bool
}

protocol ConnectivityPathMonitoring: AnyObject {
  var pathUpdateHandler: ((ConnectivityPathValue) -> Void)? { get set }

  func start(queue: DispatchQueue)
  func cancel()
}

final class NetworkConnectivityPathMonitor: ConnectivityPathMonitoring {
  private let monitor = NWPathMonitor()

  var pathUpdateHandler: ((ConnectivityPathValue) -> Void)? {
    didSet {
      monitor.pathUpdateHandler = { [weak self] path in
        self?.pathUpdateHandler?(ConnectivityPathValue(path))
      }
    }
  }

  func start(queue: DispatchQueue) {
    monitor.start(queue: queue)
  }

  func cancel() {
    monitor.cancel()
  }
}

private final class ConnectivityMonitorEpochAuthority: @unchecked Sendable {
  static let shared = ConnectivityMonitorEpochAuthority()

  private let lock = NSLock()
  private var epoch: Int64 = 0

  func next() -> Int64 {
    lock.lock()
    defer { lock.unlock() }
    precondition(epoch < Int64.max, "Connectivity monitor epoch exhausted")
    epoch += 1
    return epoch
  }
}

final class ConnectivityApiImpl: ConnectivityApi {
  private let flutterApi: ConnectivityFlutterApiProtocol
  private let monitorFactory: () -> ConnectivityPathMonitoring
  private let lifecycleQueue = DispatchQueue(label: "ConnectivityMonitor.Lifecycle")
  private let updateQueue = DispatchQueue(label: "ConnectivityMonitor.Updates")
  private let lock = NSLock()
  private var monitor: ConnectivityPathMonitoring?
  private var currentPath: ConnectivityPathValue?
  private var monitorEpoch: Int64 = 0
  private var pathRevision: Int64 = 0

  init(
    flutterApi: ConnectivityFlutterApiProtocol,
    monitorFactory: @escaping () -> ConnectivityPathMonitoring = {
      NetworkConnectivityPathMonitor()
    }
  ) {
    self.flutterApi = flutterApi
    self.monitorFactory = monitorFactory
  }

  deinit {
    try? stop()
  }

  func readCurrentSnapshot() throws -> ConnectivityTransportSnapshot {
    lock.lock()
    let snapshot = Self.snapshot(
      for: currentPath,
      monitorEpoch: monitorEpoch,
      revision: pathRevision
    )
    lock.unlock()
    return snapshot
  }

  func start() throws {
    lifecycleQueue.sync {
      lock.lock()
      guard monitor == nil else {
        lock.unlock()
        return
      }

      monitorEpoch = ConnectivityMonitorEpochAuthority.shared.next()
      pathRevision = 0
      let epoch = monitorEpoch
      let monitor = monitorFactory()
      let monitorIdentifier = ObjectIdentifier(monitor)
      monitor.pathUpdateHandler = { [weak self] path in
        self?.receive(path, from: monitorIdentifier, epoch: epoch)
      }
      self.monitor = monitor
      lock.unlock()
      monitor.start(queue: updateQueue)
    }
  }

  func stop() throws {
    lifecycleQueue.sync {
      lock.lock()
      guard monitor != nil else {
        lock.unlock()
        return
      }
      monitorEpoch = ConnectivityMonitorEpochAuthority.shared.next()
      pathRevision = 0
      let monitor = monitor
      self.monitor = nil
      currentPath = nil
      lock.unlock()
      monitor?.cancel()
    }
  }

  func dispose() throws {
    try stop()
  }

  private func receive(
    _ path: ConnectivityPathValue,
    from monitorIdentifier: ObjectIdentifier,
    epoch: Int64
  ) {
    lock.lock()
    guard
      let activeMonitor = monitor,
      ObjectIdentifier(activeMonitor) == monitorIdentifier,
      monitorEpoch == epoch
    else {
      lock.unlock()
      return
    }
    currentPath = path
    pathRevision &+= 1
    let snapshot = Self.snapshot(
      for: path,
      monitorEpoch: monitorEpoch,
      revision: pathRevision
    )
    lock.unlock()

    flutterApi.onTransportChanged(snapshot: snapshot) { _ in }
  }

  private static func snapshot(
    for path: ConnectivityPathValue?,
    monitorEpoch: Int64,
    revision: Int64
  ) -> ConnectivityTransportSnapshot {
    guard let path else {
      return ConnectivityTransportSnapshot(
        availability: .unknown,
        capabilities: [],
        monitorEpoch: monitorEpoch,
        revision: revision
      )
    }
    switch path.status {
    case .unknown, .requiresConnection:
      return ConnectivityTransportSnapshot(
        availability: .unknown,
        capabilities: [],
        monitorEpoch: monitorEpoch,
        revision: revision
      )
    case .unsatisfied:
      return ConnectivityTransportSnapshot(
        availability: .unavailable,
        capabilities: [],
        monitorEpoch: monitorEpoch,
        revision: revision
      )
    case .satisfied:
      return ConnectivityTransportSnapshot(
        availability: .available,
        capabilities: capabilities(for: path),
        monitorEpoch: monitorEpoch,
        revision: revision
      )
    }
  }

  private static func capabilities(
    for path: ConnectivityPathValue
  ) -> [ConnectivityNetworkCapability] {
    var capabilities: [ConnectivityNetworkCapability] = []
    if path.usesCellular {
      capabilities.append(.cellular)
    }
    if path.usesWifi {
      capabilities.append(.wifi)
    }
    if path.usesOther {
      capabilities.append(.vpn)
    }
    if path.usesWifi && !path.usesCellular && !path.isExpensive && !path.isConstrained {
      capabilities.append(.unmetered)
    }
    return capabilities
  }
}

extension ConnectivityPathValue {
  fileprivate init(_ path: NWPath) {
    switch path.status {
    case .satisfied:
      status = .satisfied
    case .unsatisfied:
      status = .unsatisfied
    case .requiresConnection:
      status = .requiresConnection
    @unknown default:
      status = .unknown
    }
    usesCellular = path.usesInterfaceType(.cellular)
    usesWifi = path.usesInterfaceType(.wifi)
    usesOther = path.usesInterfaceType(.other)
    isExpensive = path.isExpensive
    isConstrained = path.isConstrained
  }
}
