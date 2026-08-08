import Foundation
import Network

final class ConnectivityApiImpl: ConnectivityApi {
  private let flutterApi: ConnectivityFlutterApi
  private let queue = DispatchQueue(label: "ConnectivityMonitor")
  private let lock = NSLock()
  private var monitor: NWPathMonitor?
  private var currentPath: NWPath?

  init(flutterApi: ConnectivityFlutterApi) {
    self.flutterApi = flutterApi
  }

  deinit {
    stop()
  }

  func getSnapshot() -> ConnectivityTransportSnapshot {
    lock.lock()
    let path = currentPath
    lock.unlock()
    return Self.snapshot(for: path)
  }

  func start() {
    lock.lock()
    guard monitor == nil else {
      lock.unlock()
      return
    }

    let monitor = NWPathMonitor()
    monitor.pathUpdateHandler = { [weak self] path in
      self?.receive(path)
    }
    self.monitor = monitor
    lock.unlock()
    monitor.start(queue: queue)
  }

  func stop() {
    lock.lock()
    let monitor = monitor
    self.monitor = nil
    currentPath = nil
    lock.unlock()
    monitor?.cancel()
  }

  func dispose() {
    stop()
  }

  private func receive(_ path: NWPath) {
    lock.lock()
    guard monitor != nil else {
      lock.unlock()
      return
    }
    currentPath = path
    lock.unlock()

    flutterApi.onTransportChanged(snapshot: Self.snapshot(for: path)) { _ in }
  }

  private static func snapshot(for path: NWPath?) -> ConnectivityTransportSnapshot {
    guard let path, path.status == .satisfied else {
      return ConnectivityTransportSnapshot(
        availability: .unavailable,
        capabilities: []
      )
    }

    return ConnectivityTransportSnapshot(
      availability: .available,
      capabilities: capabilities(for: path)
    )
  }

  private static func capabilities(for path: NWPath) -> [ConnectivityNetworkCapability] {
    var capabilities: [ConnectivityNetworkCapability] = []
    let isOnWifi = path.usesInterfaceType(.wifi)
    let isOnCellular = path.usesInterfaceType(.cellular)

    if isOnCellular {
      capabilities.append(.cellular)
    }
    if isOnWifi {
      capabilities.append(.wifi)
    }
    if path.usesInterfaceType(.other) {
      capabilities.append(.vpn)
    }
    if isOnWifi && !isOnCellular && !path.isExpensive && !path.isConstrained {
      capabilities.append(.unmetered)
    }
    return capabilities
  }
}
