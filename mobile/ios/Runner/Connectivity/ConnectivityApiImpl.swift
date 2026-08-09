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

final class ConnectivityApiImpl: ConnectivityApi {
  private let flutterApi: ConnectivityFlutterApiProtocol
  private let monitorFactory: () -> ConnectivityPathMonitoring
  private let lifecycleQueue = DispatchQueue(label: "ConnectivityMonitor.Lifecycle")
  private let updateQueue = DispatchQueue(label: "ConnectivityMonitor.Updates")
  private let lock = NSLock()
  private var monitor: ConnectivityPathMonitoring?
  private var currentPath: ConnectivityPathValue?
  private var monitorRevision = 0

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

  func getSnapshot() throws -> ConnectivityTransportSnapshot {
    lock.lock()
    let path = currentPath
    lock.unlock()
    return Self.snapshot(for: path)
  }

  func start() throws {
    lifecycleQueue.sync {
      lock.lock()
      guard monitor == nil else {
        lock.unlock()
        return
      }

      monitorRevision &+= 1
      let revision = monitorRevision
      let monitor = monitorFactory()
      let monitorIdentifier = ObjectIdentifier(monitor)
      monitor.pathUpdateHandler = { [weak self] path in
        self?.receive(path, from: monitorIdentifier, revision: revision)
      }
      self.monitor = monitor
      lock.unlock()
      monitor.start(queue: updateQueue)
    }
  }

  func stop() throws {
    lifecycleQueue.sync {
      lock.lock()
      monitorRevision &+= 1
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
    revision: Int
  ) {
    lock.lock()
    guard
      let activeMonitor = monitor,
      ObjectIdentifier(activeMonitor) == monitorIdentifier,
      monitorRevision == revision
    else {
      lock.unlock()
      return
    }
    currentPath = path
    lock.unlock()

    flutterApi.onTransportChanged(snapshot: Self.snapshot(for: path)) { _ in }
  }

  private static func snapshot(for path: ConnectivityPathValue?) -> ConnectivityTransportSnapshot {
    guard let path else {
      return ConnectivityTransportSnapshot(availability: .unknown, capabilities: [])
    }
    switch path.status {
    case .unknown, .requiresConnection:
      return ConnectivityTransportSnapshot(availability: .unknown, capabilities: [])
    case .unsatisfied:
      return ConnectivityTransportSnapshot(availability: .unavailable, capabilities: [])
    case .satisfied:
      return ConnectivityTransportSnapshot(
        availability: .available,
        capabilities: capabilities(for: path)
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
